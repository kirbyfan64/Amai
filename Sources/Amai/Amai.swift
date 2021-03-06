/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */


import CGtk


func combine(hashes: [Int]) -> Int {
    return hashes.reduce(0) {(result: Int, current) in
        result ^ (current + 0x9e3779b9 + (result << 6) + (result >> 2))
    }
}


func hash<T: Hashable>(items: [T]) -> Int {
    return combine(hashes: items.map { $0.hashValue })
}


extension Array: Hashable where Element: Hashable {
    public var hashValue: Int {
        return hash(items: self)
    }
}


/// A key is an object that is used to compare widgets for equality. Differences will
/// cause the widget to be rebuilt.
///
/// You can create your own keys by subclassing it and implementing `Key.equals` and
/// `Key.hashValue`. This default implementation compares keys via object identity.
///
/// **Note that, in 99% of cases, you'll want to use `AutoKey` instead.**
public class Key: Hashable {
    public init() {}

    public static func == (lhs: Key, rhs: Key) -> Bool {
        return lhs.equals(rhs)
    }

    public func equals(_ rhs: Key) -> Bool {
        return self === rhs
    }

    public var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}


/// A `Key` that's always equal to any other `NullKey`. This is primarily a stub used for
/// default initialization so that you can later use an `AutoKey` instead.
public class NullKey: Key {
    public override func equals(_ rhs: Key) -> Bool {
        return true
    }

    public override var hashValue: Int {
        return 0
    }
}


/// A `Key` that takes a hashable object and wraps it, forwarding equality and hashValue
/// tests to the underlying object. A common pattern you'll see in Amai code is:
///
/// ```swift
/// struct MyWidget: StatelessWidget, HashableWidget {
///     var key: Key = NullKey()
///     init() {
///         self.key = AutoKey(self)
///     }
/// }
/// ```
///
/// Here, the widget's `AutoKey` wraps itself.
public class AutoKey<Wrapped: Hashable>: Key {
    var wrapped: Wrapped

    public init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }

    public override func equals(_ rhs: Key) -> Bool {
        guard let rhsAutoKey = rhs as? AutoKey else {
            return false
        }
        return wrapped == rhsAutoKey.wrapped
    }

    public override var hashValue: Int {
        return wrapped.hashValue
    }
}


func getPointer<Ty: AnyObject>(fromObject object: Ty) -> UnsafeMutableRawPointer {
    return Unmanaged.passUnretained(object).toOpaque()
}


func getObject<Target: AnyObject>(fromPointer ptr: UnsafeMutableRawPointer,
                                  to: Target.Type) ->
        Target {
    return Unmanaged.fromOpaque(ptr).takeUnretainedValue()
}


func gcast<Source, Target>(_ ptr: UnsafeMutablePointer<Source>,
                           to target: Target.Type) -> UnsafeMutablePointer<Target> {
    return UnsafeMutableRawPointer(ptr).bindMemory(to: target, capacity: 1)
}


func gCallbackFrom<Func>(closure: Func) -> GCallback {
    return unsafeBitCast(closure, to: GCallback.self)
}


protocol GBindings {
    static func from(_ cself: UnsafeMutableRawPointer) -> Self
    func connect<GObj, Closure>(toObject: UnsafeMutablePointer<GObj>, signal: String,
                                closure: Closure)
}


extension GBindings where Self: AnyObject {
    static func from(_ cself: UnsafeMutableRawPointer) -> Self {
        return getObject(fromPointer: cself, to: Self.self)
    }

    func connect<GObj, Closure>(toObject object: UnsafeMutablePointer<GObj>,
                                signal: String, closure: Closure) {
        g_signal_connect_data(UnsafeMutableRawPointer(object), signal,
                              gCallbackFrom(closure: closure),
                              getPointer(fromObject: self), nil,
                              GConnectFlags(rawValue: 0))
    }
}


/// The core build context, passed around between widgets for building.
public class BuildContext: GBindings {
    var activeStates: [Key: State] = [:]
    var reActiveStates: [Key: State] = [:]
    var ensureUpdatedNextIteration: [State] = []
    var rootNode: RenderNode? = nil
    var app: Application
    var gtkApp: UnsafeMutablePointer<GtkApplication>
    var building: Bool = false
    var updateSourceId: guint = 0

    let maxIterations = 500

    init(app: Application) {
        self.app = app
        gtkApp = gtk_application_new(app.id, GApplicationFlags(rawValue: 0))

        let closure: @convention(c)
            (UnsafeMutablePointer<GtkApplication>,
             UnsafeMutableRawPointer) -> Void = {(app, cself) in
                BuildContext.from(cself).buildIteration()
            }
        connect(toObject: gtkApp, signal: "activate", closure: closure)
    }

    func runApp() {
        g_application_run(gcast(gtkApp, to: GApplication.self), 0, nil)
    }

    deinit {
        if (updateSourceId != 0) {
            g_source_remove(updateSourceId)
            updateSourceId = 0
        }
        g_object_unref(gtkApp)
    }

    func build(widget: Widget) -> RenderWidget {
        var current = widget

        for _ in 0..<maxIterations {
            switch current {
            case let stateless as StatelessWidget:
                current = stateless.build(ctx: self)
            case let stateful as StatefulWidget:
                let state = activeStates[current.key] ?? stateful.createState(ctx: self)
                reActiveStates[current.key] = state
                current = state.build(ctx: self)
            case let current as RenderWidget:
                return current as RenderWidget
            default:
                preconditionFailure("Invalid widget \(widget) in BuildContext.build.")
            }
        }

        preconditionFailure("Tried building \(widget), but didn't get RenderWidget " +
                            "after \(maxIterations) iterations.")
    }

    func updateNodeIfNecessary(node: RenderNode?, widget: Widget,
                               onChange: (RenderNode) -> Void) {
        let renderWidget = build(widget: widget)

        let applicationResult = node?.applyChanges(ctx: self, from: renderWidget) ??
                                RenderApplicationResult.newNode(
                                    node: renderWidget.buildRenderNode(ctx: self))
        if case RenderApplicationResult.newNode(let newNode) = applicationResult {
            onChange(newNode)
        }
    }

    func buildIteration() {
        building = true
        guard let rootRender = build(widget: app.root) as? Window else {
            preconditionFailure("Root widget must be Window.")
        }

        updateNodeIfNecessary(node: rootNode, widget: rootRender, onChange: {n in
            rootNode = n
            gtk_widget_show_all(rootNode!.gwidget)
        })

        activeStates = reActiveStates
        reActiveStates.removeAll()

        building = false
    }

    public func setState(setter: () -> Void) {
        precondition(!building, "Cannot call setState while building.")

        setter()

        if (updateSourceId == 0) {
            let closure: @convention(c) (UnsafeMutableRawPointer?) -> Int32 =
                {(cself) in
                    let ctx = BuildContext.from(cself!)
                    ctx.buildIteration()
                    ctx.updateSourceId = 0
                    return 0
                }

            updateSourceId = g_idle_add_full(G_PRIORITY_HIGH, closure,
                                             getPointer(fromObject: self), nil)
        }
    }
}


protocol TypeErasedHashable {
    func equals(_ rhs: TypeErasedHashable) -> Bool
    var hashValue: Int { get }
}


extension TypeErasedHashable where Self: AnyObject {
    func equals(_ rhs: TypeErasedHashable) -> Bool {
        guard let rhsSelf = rhs as? Self else {
            return false
        }
        return self === rhsSelf
    }

    var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}


struct TypeErasedHashableWrapper: Hashable {
    var inner: TypeErasedHashable

    static func == (lhs: TypeErasedHashableWrapper, rhs: TypeErasedHashableWrapper) ->
            Bool {
        return lhs.inner.equals(rhs.inner)
    }

    public var hashValue: Int {
        return inner.hashValue
    }
}


/// A signal handler that can be attached to widget signals. These should be created
/// once per widget in order to avoid needless widget rebuilds.
public class Handler<Func>: TypeErasedHashable {
    var function: Func

    /// Create a signal handler that calls the given function.
    public init(_ function: Func) {
        self.function = function
    }
}


/// Like a `Handler`, except it calls an unbound method that must be later bound.
/// Example:
///
/// ```swift
/// class MyWidget: StatelessWidget, HashableWidget {
///     func onClick() {}
///     static let onClickHandler = MethodHandler(onClick)
///     ...
///     func build(ctx: BuildContext) -> Widget {
///         return Button(
///             Button.onClick => MyWidget.onClickHandler.bind(to: self)
///         )
/// }
/// }
/// ```
public class MethodHandler<Parent, Func>: TypeErasedHashable {
    var method: (Parent) -> Func

    public init(_ method: @escaping (Parent) -> Func) {
        self.method = method
    }

    public func bind(to parent: Parent) -> BoundMethodHandler<Parent, Func> {
        return BoundMethodHandler(createdBy: self, function: self.method(parent))
    }
}


public class BoundMethodHandler<Parent, Func>: Handler<Func> {
    weak var creator: MethodHandler<Parent, Func>!

    public init(createdBy creator: MethodHandler<Parent, Func>, function: Func) {
        self.creator = creator
        super.init(function)
    }

    func equals(rhs: TypeErasedHashable) -> Bool {
        guard let rhsHandler = rhs as? BoundMethodHandler<Parent, Func> else {
            return false
        }
        return self.creator.equals(rhsHandler.creator)
    }

    public var hashValue: Int {
        return self.creator.hashValue
    }
}


public struct SignalConnection: Hashable {
    var signal: TypeErasedHashableWrapper
    var handler: TypeErasedHashableWrapper
}


infix operator =>


public class SignalId<Func>: TypeErasedHashable {
    public static func => (signal: SignalId<Func>, handler: Handler<Func>) ->
            SignalConnection {
        return SignalConnection(signal: TypeErasedHashableWrapper(inner: signal),
                                handler: TypeErasedHashableWrapper(inner: handler))
    }

    public static func == (lhs: SignalId<Func>, rhs: SignalId<Func>) -> Bool {
        return lhs === rhs
    }

    public var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}


public struct SignalConnectionGroup: Hashable {
    var connections: [SignalConnection]

    public init(_ connections: [SignalConnection]) {
        self.connections = connections
    }

    public func map<Func>(signal: SignalId<Func>, _ callback: (Func) -> Bool) {
        for connection in connections {
            guard let connSignal = connection.signal.inner as? SignalId<Func> else {
                continue
            }
            guard connSignal == signal else {
                continue
            }

            let handler = connection.handler.inner as! Handler<Func>
            if !callback(handler.function) {
                break
            }
        }
    }

    public var hashValue: Int {
        return hash(items: connections)
    }
}


/// The base widget protocol, to be implemented by custom widgets.
public protocol Widget {
    var key: Key { get }
}


/// A nicer way to say your `Widget` should be hashable.
public protocol HashableWidget: Widget, Hashable {}


/// A wrapper over a `Widget` that allows you to store them in a `Hashable` type.
public class Keyed<Type>: Equatable, Hashable {
    public private(set) var inner: Type? = nil
    public private(set) var key: Key

    public init(key: Key, inner: Type? = nil) {
        self.key = key
        self.inner = inner
    }

    public init(widget: Type) {
        self.key = (widget as! Widget).key
        self.inner = widget
    }

    public static func == (lhs: Keyed<Type>, rhs: Keyed<Type>) -> Bool {
        return lhs.key == rhs.key
    }

    public var hashValue: Int {
        return key.hashValue
    }
}


public protocol StatelessWidget: Widget {
    func build(ctx: BuildContext) -> Widget
}

public protocol StatefulWidget: Widget {
    func createState(ctx: BuildContext) -> State
}


public protocol State {
    var ctx: BuildContext { get }
    func build(ctx: BuildContext) -> Widget
    func setState(setter: () -> Void)
}

extension State {
    public func setState(setter: () -> Void) {
        ctx.setState(setter: setter)
    }
}


protocol RenderWidget: Widget {
    func buildRenderNode(ctx: BuildContext) -> RenderNode
}


enum RenderApplicationResult {
    case keepSelf
    case newNode(node: RenderNode)
}


public enum Justify: Hashable {
    case left, right, center, fill

    func toGtk() -> GtkJustification {
        switch self {
        case Justify.left:
            return GTK_JUSTIFY_LEFT
        case Justify.right:
            return GTK_JUSTIFY_RIGHT
        case Justify.center:
            return GTK_JUSTIFY_CENTER
        case Justify.fill:
            return GTK_JUSTIFY_FILL
        }
    }
}


/// A window widget. This widget should be the "root" widget of all your Amai projects.
public struct Window: RenderWidget, HashableWidget {
    public var key: Key = NullKey()
    public var title: String
    public var width: Int
    public var height: Int
    public var hasTitleBar: Bool
    public var child: Keyed<Widget>

    public init(key: Key? = nil, title: String = "Amai", width: Int = 800,
                height: Int = 600, hasTitleBar: Bool = true, child: Widget) {
        self.title = title
        self.width = width
        self.height = height
        self.hasTitleBar = hasTitleBar
        self.child = Keyed(widget: child)

        self.key = key ?? AutoKey(self)
    }

    func buildRenderNode(ctx: BuildContext) -> RenderNode {
        let node = WindowRenderNode(ctx: ctx)
        return node.applyChangesReceivingNode(ctx: ctx, from: self)
    }
}


/// A simple text label. Shows the given text with the given justification.
public struct Label: RenderWidget, HashableWidget {
    public var key: Key = NullKey()
    public var text: String
    public var justify: Justify

    public init(key: Key? = nil, text: String, justify: Justify = Justify.left) {
        self.text = text
        self.justify = justify

        self.key = key ?? AutoKey(self)
    }

    func buildRenderNode(ctx: BuildContext) -> RenderNode {
        let node = LabelRenderNode(ctx: ctx)
        return node.applyChangesReceivingNode(ctx: ctx, from: self)
    }
}


public class InputStateManager {
    var node: InputRenderNode?

    public init() {}

    public var text: String {
        return node?.text ?? ""
    }
}


/// An input box.
public struct Input: RenderWidget, HashableWidget {
    public enum Purpose: Hashable {
        /// Allow anything.
        case anything
        case alpha
        /// Allow only digits.
        case digits
        /// Allow only numbers (like digits, but includes exponents and decimals).
        case number
        case phone
        case url
        case email
        case name
        case password
        case pin
    }

    public var key: Key = NullKey()
    public var placeholder: String
    public var purpose: Purpose
    public var manager: Keyed<InputStateManager?>
    var connections: SignalConnectionGroup

    public init(key: Key? = nil, placeholder: String = "",
                purpose: Purpose = Purpose.anything,
                managedBy manager: InputStateManager? = nil,
                _ connections: SignalConnection...) {
        self.placeholder = placeholder
        self.purpose = purpose
        self.manager = Keyed<InputStateManager?>(key: Key(), inner: manager)
        self.connections = SignalConnectionGroup(connections)

        self.key = key ?? AutoKey(self)
    }

    func buildRenderNode(ctx: BuildContext) -> RenderNode {
        let node = InputRenderNode(ctx: ctx)
        return node.applyChangesReceivingNode(ctx: ctx, from: self)
    }

    /// Emitted when the text is changed.
    public static let onChanged: SignalId<(String) -> Void> = SignalId()
}


/// A button.
public struct Button: RenderWidget, HashableWidget {
    public var key: Key = NullKey()
    public var text: String
    var connections: SignalConnectionGroup

    public init(key: Key? = nil, text: String, _ connections: SignalConnection...) {
        self.text = text
        self.connections = SignalConnectionGroup(connections)

        self.key = key ?? AutoKey(self)
    }

    func buildRenderNode(ctx: BuildContext) -> RenderNode {
        let node = ButtonRenderNode(ctx: ctx)
        return node.applyChangesReceivingNode(ctx: ctx, from: self)
    }

    /// Emitted when a button is clicked.
    public static let onClick: SignalId<() -> Void> = SignalId()
}


/// A grid. This is the core layout component of Amai (and GTK+).
///
/// Grids contain a set of `Grid.Item` values, each of which is positions either
/// absolutely or relatively on the grid.
public struct Grid: RenderWidget, HashableWidget {
    /// The position of an item on the grid.
    public enum Position: Hashable {
        case unspecified, above, below, left, right
    }

    /// Homogenity of grid items: are they homogenous on rows, columns, both, or none?
    public enum Homogenous: Hashable {
        case all, row, column, none
    }

    public struct Location: Hashable {
        public enum How {
            case absolute, relative
        }

        /// Determines whether this is location is relative to the previous grid item, or
        /// is absolute.
        public var how: How
        /// The horizontal cell the grid item is in.
        public var x: Int
        /// The vertical cell the grid item is in.
        public var y: Int

        public init(_ how: How, x: Int, y: Int) {
            self.how = how
            self.x = x
            self.y = y
        }

        /// A shortcut to create a new absolute location.
        public static func absolute(x: Int, y: Int) -> Location {
            return Location(.absolute, x: x, y: y)
        }

        /// A shortcut to create a new relative location.
        public static func relative(x: Int, y: Int) -> Location {
            return Location(.relative, x: x, y: y)
        }

        public func with(how: How? = nil,
                         _ callback: ((x: Int, y: Int)) -> (x: Int, y: Int)) ->
                Location {
            let result = callback((x: x, y: y))
            return Location(how ?? self.how, x: result.x, y: result.y)
        }
    }

    /// Determines the width and height of a grid item.
    public struct Size: Hashable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    /// A grid item. Holds a child widget, origin location, size, and position.
    public struct Item: Hashable {
        var origin: Location?
        var size: Size
        var position: Position
        var child: Keyed<Widget>

        public init(from origin: Location, to target: Location, child: Widget) {
            self.origin = origin
            self.size = Size(x: target.x - origin.x, y: target.y - origin.y)
            self.child = Keyed(widget: child)
            self.position = Position.unspecified

            assert(self.size.x > 0, "Target is to the left of origin.")
            assert(self.size.y > 0, "Target is above origin.")
        }

        public init(from origin: Location? = nil, size: Size = Size(x: 1, y: 1),
             position: Position = Position.unspecified, child: Widget) {
            self.origin = origin
            self.size = size
            self.position = position
            self.child = Keyed(widget: child)
        }

        public var hashValue: Int {
            var hashes = [size.hashValue, position.hashValue, child.hashValue]

            if let origin = origin {
                hashes.append(origin.hashValue)
            }

            return combine(hashes: hashes)
        }
    }

    public var key: Key = NullKey()
    public var defaultPosition: Position
    public var homogenous: Homogenous
    public var items: [Item]

    public init(key: Key? = nil, defaultPosition: Position = Position.unspecified,
                homogenous: Homogenous = Homogenous.none, items: [Item]) {
        self.defaultPosition = defaultPosition
        self.homogenous = homogenous
        self.items = items

        self.key = key ?? AutoKey(self)
    }

    public init(key: Key? = nil, homogenous: Homogenous = Homogenous.none, row: [Item]) {
        self.init(key: key, defaultPosition: Position.right, homogenous: homogenous,
                  items: row)
    }

    public init(key: Key? = nil, homogenous: Homogenous = Homogenous.none,
                row: [Widget]) {
        self.init(key: key, homogenous: homogenous, row: row.map { Item(child: $0) })
    }

    public init(key: Key? = nil, homogenous: Homogenous = Homogenous.none,
                column: [Item]) {
        self.init(key: key, defaultPosition: Position.below, homogenous: homogenous,
                  items: column)
    }

    public init(key: Key? = nil, homogenous: Homogenous = Homogenous.none,
                column: [Widget]) {
        self.init(key: key, homogenous: homogenous,
                  column: column.map { Item(child: $0) })
    }

    func buildRenderNode(ctx: BuildContext) -> RenderNode {
        let node = GridRenderNode(ctx: ctx)
        return node.applyChangesReceivingNode(ctx: ctx, from: self)
    }
}


protocol RenderNode {
    var gwidget: UnsafeMutablePointer<GtkWidget> { get }
    init(ctx: BuildContext)
    func applyChanges(ctx: BuildContext, from widget: RenderWidget) ->
            RenderApplicationResult
    func applyChangesReceivingNode(ctx: BuildContext, from widget: RenderWidget) ->
            RenderNode
}


extension RenderNode {
    func applyChangesReceivingNode(ctx: BuildContext, from widget: RenderWidget)
            -> RenderNode {
        switch applyChanges(ctx: ctx, from: widget) {
        case .keepSelf:
            return self
        case .newNode(let node):
            return node
        }
    }
}


class RenderNodeDefaults<GtkWidgetType> {
    var gwidget: UnsafeMutablePointer<GtkWidget>
    var gwidgetCast: UnsafeMutablePointer<GtkWidgetType> {
        return gcast(gwidget, to: GtkWidgetType.self)
    }

    init(withWidget gwidget: UnsafeMutablePointer<GtkWidget>) {
        self.gwidget = gwidget
    }
}


class WindowRenderNode: RenderNodeDefaults<GtkWindow>, RenderNode {
    var child: RenderNode?

    required init(ctx: BuildContext) {
        let gwidget = UnsafeMutablePointer(gtk_application_window_new(ctx.gtkApp)!)
        super.init(withWidget: gwidget)
    }

    func applyChanges(ctx: BuildContext, from widget: RenderWidget) ->
            RenderApplicationResult {
        guard let window = widget as? Window else {
            return RenderApplicationResult.newNode(node:
                widget.buildRenderNode(ctx: ctx))
        }

        gtk_window_set_title(gwidgetCast, window.title)
        gtk_window_set_default_size(gwidgetCast, gint(window.width), gint(window.height))

        ctx.updateNodeIfNecessary(node: child, widget: window.child.inner!,
            onChange: {n in
                let gcontainer = gcast(gwidget, to: GtkContainer.self)
                if (child != nil) {
                    gtk_container_remove(gcontainer, child!.gwidget)
                }
                child = n
                gtk_container_add(gcontainer, child!.gwidget)
            }
        )

        return RenderApplicationResult.keepSelf
    }
}


class LabelRenderNode: RenderNodeDefaults<GtkLabel>, RenderNode, GBindings {
    required init(ctx: BuildContext) {
        let gwidget = UnsafeMutablePointer(gtk_label_new("")!)
        super.init(withWidget: gwidget)
    }

    func applyChanges(ctx: BuildContext, from widget: RenderWidget) ->
            RenderApplicationResult {
        guard let label = widget as? Label else {
            return RenderApplicationResult.newNode(node:
                widget.buildRenderNode(ctx: ctx))
        }

        gtk_label_set_text(gwidgetCast, label.text)
        gtk_label_set_justify(gwidgetCast, label.justify.toGtk())

        return RenderApplicationResult.keepSelf
    }
}


class InputRenderNode: RenderNodeDefaults<GtkEntry>, RenderNode, GBindings {
    var connections: SignalConnectionGroup? = nil

    required init(ctx: BuildContext) {
        let gwidget = UnsafeMutablePointer(gtk_entry_new()!)
        super.init(withWidget: gwidget)

        let closure: @convention(c)
            (UnsafeMutablePointer<GtkEditable>,
             UnsafeMutableRawPointer) -> Void = {(_, cself) in
                InputRenderNode.from(cself).changed()
            }
        connect(toObject: gwidget, signal: "changed", closure: closure)
    }

    func convertPurpose(_ purpose: Input.Purpose) ->
            (purpose: GtkInputPurpose, hidden: Bool) {
        switch purpose {
        case Input.Purpose.anything:
            return (purpose: GTK_INPUT_PURPOSE_FREE_FORM, hidden: false)
        case Input.Purpose.alpha:
            return (purpose: GTK_INPUT_PURPOSE_ALPHA, hidden: false)
        case Input.Purpose.digits:
            return (purpose: GTK_INPUT_PURPOSE_DIGITS, hidden: false)
        case Input.Purpose.number:
            return (purpose: GTK_INPUT_PURPOSE_NUMBER, hidden: false)
        case Input.Purpose.phone:
            return (purpose: GTK_INPUT_PURPOSE_PHONE, hidden: false)
        case Input.Purpose.url:
            return (purpose: GTK_INPUT_PURPOSE_URL, hidden: false)
        case Input.Purpose.email:
            return (purpose: GTK_INPUT_PURPOSE_EMAIL, hidden: false)
        case Input.Purpose.name:
            return (purpose: GTK_INPUT_PURPOSE_NAME, hidden: false)
        case Input.Purpose.password:
            return (purpose: GTK_INPUT_PURPOSE_PASSWORD, hidden: true)
        case Input.Purpose.pin:
            return (purpose: GTK_INPUT_PURPOSE_PIN, hidden: true)
        }
    }

    func applyChanges(ctx: BuildContext, from widget: RenderWidget) ->
            RenderApplicationResult {
        guard let input = widget as? Input else {
            return RenderApplicationResult.newNode(node:
                widget.buildRenderNode(ctx: ctx))
        }

        if let manager = input.manager.inner {
            manager!.node = self
        }

        gtk_entry_set_placeholder_text(gwidgetCast, input.placeholder)
        let (purpose: purpose, hidden: hidden) = convertPurpose(input.purpose)
        gtk_entry_set_visibility(gwidgetCast, hidden ? 0 : 1)

        var purposeValue = GValue()
        // G_TYPE_INT == 6 << 2
        g_value_init(&purposeValue, 6 << 2)
        g_value_set_int(&purposeValue, gint(purpose.rawValue))
        g_object_set_property(gcast(gwidget, to: GObject.self), "input-purpose",
                              &purposeValue)
        g_value_unset(&purposeValue)

        connections = input.connections

        return RenderApplicationResult.keepSelf
    }

    var text: String {
        return String(cString: gtk_entry_get_text(gwidgetCast))
    }

    func changed() {
        guard let connections = self.connections else {
            return
        }

        let text = self.text
        connections.map(signal: Input.onChanged) { $0(text); return true }
    }
}


class ButtonRenderNode: RenderNodeDefaults<GtkButton>, RenderNode, GBindings {
    var connections: SignalConnectionGroup? = nil

    required init(ctx: BuildContext) {
        let gwidget = UnsafeMutablePointer(gtk_button_new()!)
        super.init(withWidget: gwidget)

        let closure: @convention(c)
            (UnsafeMutablePointer<GtkButton>,
             UnsafeMutableRawPointer) -> Void = {(_, cself) in
                ButtonRenderNode.from(cself).clicked()
            }
        connect(toObject: gwidget, signal: "clicked", closure: closure)
    }

    func applyChanges(ctx: BuildContext, from widget: RenderWidget) ->
            RenderApplicationResult {
        guard let button = widget as? Button else {
            return RenderApplicationResult.newNode(node:
                widget.buildRenderNode(ctx: ctx))
        }

        gtk_button_set_label(gwidgetCast, button.text)
        connections = button.connections

        return RenderApplicationResult.keepSelf
    }

    func clicked() {
        guard let connections = self.connections else {
            return
        }

        connections.map(signal: Button.onClick) { $0(); return true }
    }
}


class GridRenderNode: RenderNodeDefaults<GtkGrid>, RenderNode, GBindings {
    var children: [RenderNode] = []

    required init(ctx: BuildContext) {
        let gwidget = UnsafeMutablePointer(gtk_grid_new()!)
        super.init(withWidget: gwidget)
    }

    func calculateOrigin(item: Grid.Item, previousOrigin: Grid.Location,
                         previousSize: Grid.Size, defaultPosition: Grid.Position) ->
            Grid.Location {
        guard let origin = item.origin else {
            var position = item.position
            if case Grid.Position.unspecified = position {
                position = defaultPosition
            }

            switch position {
            case .unspecified:
                preconditionFailure("\(item) cannot have defaultPosition: " +
                                    ".unspecified and parent have position: " +
                                    ".unspecified.")
            case .above:
                return previousOrigin.with { (x: $0.x, y: $0.y - previousSize.y) }
            case .below:
                return previousOrigin.with { (x: $0.x, y: $0.y + previousSize.y) }
            case .left:
                return previousOrigin.with { (x: $0.x - previousSize.x, y: $0.y) }
            case .right:
                return previousOrigin.with { (x: $0.x + previousSize.x, y: $0.y) }
            }
        }

        switch origin.how {
        case .absolute:
            return origin
        case .relative:
            return origin.with(how: Grid.Location.How.absolute) {
                (x: $0.x + previousOrigin.x, y: $0.y + previousOrigin.y)
            }
        }
    }

    func applyChanges(ctx: BuildContext, from widget: RenderWidget) ->
            RenderApplicationResult {
        guard let grid = widget as? Grid else {
            return RenderApplicationResult.newNode(node:
                widget.buildRenderNode(ctx: ctx))
        }

        switch grid.homogenous {
        case .all:
            gtk_grid_set_row_homogeneous(gwidgetCast, 1)
            gtk_grid_set_column_homogeneous(gwidgetCast, 1)
        case .row:
            gtk_grid_set_row_homogeneous(gwidgetCast, 1)
            gtk_grid_set_column_homogeneous(gwidgetCast, 0)
        case .column:
            gtk_grid_set_row_homogeneous(gwidgetCast, 0)
            gtk_grid_set_column_homogeneous(gwidgetCast, 1)
        case .none:
            gtk_grid_set_row_homogeneous(gwidgetCast, 0)
            gtk_grid_set_column_homogeneous(gwidgetCast, 0)
        }

        var previousOrigin = Grid.Location(Grid.Location.How.absolute, x: 0, y: 0)
        var previousSize = Grid.Size(x: 0, y: 0)

        for (i, item) in grid.items.enumerated() {
            let origin = calculateOrigin(item: item, previousOrigin: previousOrigin,
                                         previousSize: previousSize,
                                         defaultPosition: grid.defaultPosition)

            let childWidget = item.child
            let childNode = i < children.count ? children[i] : nil
            ctx.updateNodeIfNecessary(node: childNode, widget: childWidget.inner!,
                onChange: {n in
                    if i < children.count {
                        children[i] = n
                    } else {
                        assert(i == children.count)
                        children.append(n)
                    }
                }
            )

            if childNode == nil || childNode!.gwidget != children[i].gwidget {
                if let childNode = childNode {
                    gtk_widget_destroy(childNode.gwidget)
                }

                gtk_grid_attach(gwidgetCast, children[i].gwidget, gint(origin.x),
                                gint(origin.y), gint(item.size.x), gint(item.size.y))
            }

            previousOrigin = origin
            previousSize = item.size
        }

        return RenderApplicationResult.keepSelf
    }
}


/// An application that can be run.
public struct Application {
    public var id: String
    public var root: Widget

    /// Creates a new Application instance.
    ///
    /// - parameter id: A unique, reverse-DNS application ID.
    /// - parameter root: The root widget to render. This must end up building into a Window
    /// widget.
    public init(id: String, root: Widget) {
        self.id = id
        self.root = root
    }
}


/// Runs the given application.
public func run(app: Application) {
    let ctx = BuildContext(app: app)
    ctx.runApp()
}
