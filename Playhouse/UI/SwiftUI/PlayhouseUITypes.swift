#if canImport(SwiftUI)
import SwiftUI

// PlayhouseUI on Apple platforms: the SwiftUI names the atoms and composites use, under
// Playhouse's own names. The atoms and composites import PlayhouseUI and never SwiftUI
// (scripts/check-module-boundaries.py), so every view type they name comes from this list. A
// Linux build defines the same names over SwiftCrossUI, which shares SwiftUI's shape.
//
// Modifiers are SwiftUI's own, reached through these types. The ones known to be missing from
// SwiftCrossUI (context menus, shadows, hover tracking, continuous corners, materials, masks)
// go through the `ph…` shims in PlayhouseUIShims.swift instead. Nothing yet checks the other
// members the atoms and composites reach through these aliases; docs/linux-port-readiness.md
// lists them as the port's first step.

// MARK: Views and layout

public typealias PHView = SwiftUI.View
public typealias PHViewBuilder = SwiftUI.ViewBuilder
public typealias PHViewModifier = SwiftUI.ViewModifier
public typealias PHAnyView = SwiftUI.AnyView
public typealias PHEmptyView = SwiftUI.EmptyView
public typealias PHText = SwiftUI.Text
public typealias PHImage = SwiftUI.Image
public typealias PHButton<Label: SwiftUI.View> = SwiftUI.Button<Label>
public typealias PHVStack<Content: SwiftUI.View> = SwiftUI.VStack<Content>
public typealias PHHStack<Content: SwiftUI.View> = SwiftUI.HStack<Content>
public typealias PHZStack<Content: SwiftUI.View> = SwiftUI.ZStack<Content>
public typealias PHLazyVStack<Content: SwiftUI.View> = SwiftUI.LazyVStack<Content>
public typealias PHLazyHStack<Content: SwiftUI.View> = SwiftUI.LazyHStack<Content>
public typealias PHLazyVGrid<Content: SwiftUI.View> = SwiftUI.LazyVGrid<Content>
public typealias PHGridItem = SwiftUI.GridItem
public typealias PHGrid<Content: SwiftUI.View> = SwiftUI.Grid<Content>
public typealias PHGridRow<Content: SwiftUI.View> = SwiftUI.GridRow<Content>
public typealias PHSpacer = SwiftUI.Spacer
public typealias PHDivider = SwiftUI.Divider
public typealias PHForEach<Data: RandomAccessCollection, ID: Hashable, Content> = SwiftUI.ForEach<Data, ID, Content>
public typealias PHGroup<Content> = SwiftUI.Group<Content>
public typealias PHSection<Parent, Content, Footer> = SwiftUI.Section<Parent, Content, Footer>
public typealias PHScrollView<Content: SwiftUI.View> = SwiftUI.ScrollView<Content>
public typealias PHScrollViewReader<Content: SwiftUI.View> = SwiftUI.ScrollViewReader<Content>
public typealias PHScrollViewProxy = SwiftUI.ScrollViewProxy
public typealias PHGeometryReader<Content: SwiftUI.View> = SwiftUI.GeometryReader<Content>
public typealias PHGeometryProxy = SwiftUI.GeometryProxy
public typealias PHTimelineView<Schedule: SwiftUI.TimelineSchedule, Content> = SwiftUI.TimelineView<Schedule, Content>
public typealias PHLayout = SwiftUI.Layout
public typealias PHLayoutSubviews = SwiftUI.LayoutSubviews
public typealias PHLayoutValueKey = SwiftUI.LayoutValueKey
public typealias PHProposedViewSize = SwiftUI.ProposedViewSize
public typealias PHViewDimensions = SwiftUI.ViewDimensions
public typealias PHAlignment = SwiftUI.Alignment
public typealias PHHorizontalAlignment = SwiftUI.HorizontalAlignment
public typealias PHVerticalAlignment = SwiftUI.VerticalAlignment
public typealias PHTextAlignment = SwiftUI.TextAlignment
public typealias PHEdge = SwiftUI.Edge
public typealias PHEdgeInsets = SwiftUI.EdgeInsets
public typealias PHUnitPoint = SwiftUI.UnitPoint
public typealias PHAngle = SwiftUI.Angle
public typealias PHAnchor<Value> = SwiftUI.Anchor<Value>
public typealias PHPreferenceKey = SwiftUI.PreferenceKey

// MARK: Controls

public typealias PHTextField<Label: SwiftUI.View> = SwiftUI.TextField<Label>
public typealias PHSecureField<Label: SwiftUI.View> = SwiftUI.SecureField<Label>
public typealias PHToggle<Label: SwiftUI.View> = SwiftUI.Toggle<Label>
public typealias PHPicker<Label: SwiftUI.View, SelectionValue: Hashable, Content: SwiftUI.View> = SwiftUI.Picker<Label, SelectionValue, Content>
public typealias PHDatePicker<Label: SwiftUI.View> = SwiftUI.DatePicker<Label>
public typealias PHSlider<Label: SwiftUI.View, ValueLabel: SwiftUI.View> = SwiftUI.Slider<Label, ValueLabel>
public typealias PHMenu<Label: SwiftUI.View, Content: SwiftUI.View> = SwiftUI.Menu<Label, Content>
public typealias PHLabel<Title: SwiftUI.View, Icon: SwiftUI.View> = SwiftUI.Label<Title, Icon>
public typealias PHLink<Label: SwiftUI.View> = SwiftUI.Link<Label>
public typealias PHProgressView<Label: SwiftUI.View, CurrentValueLabel: SwiftUI.View> = SwiftUI.ProgressView<Label, CurrentValueLabel>
public typealias PHForm<Content: SwiftUI.View> = SwiftUI.Form<Content>
public typealias PHList<SelectionValue: Hashable, Content: SwiftUI.View> = SwiftUI.List<SelectionValue, Content>
public typealias PHNavigationSplitView<Sidebar: SwiftUI.View, Content: SwiftUI.View, Detail: SwiftUI.View> = SwiftUI.NavigationSplitView<Sidebar, Content, Detail>
public typealias PHTabView<SelectionValue: Hashable, Content: SwiftUI.View> = SwiftUI.TabView<SelectionValue, Content>
public typealias PHContentUnavailableView<Label: SwiftUI.View, Description: SwiftUI.View, Actions: SwiftUI.View> = SwiftUI.ContentUnavailableView<Label, Description, Actions>
public typealias PHButtonRole = SwiftUI.ButtonRole
public typealias PHControlSize = SwiftUI.ControlSize
public typealias PHKeyEquivalent = SwiftUI.KeyEquivalent
public typealias PHKeyboardShortcut = SwiftUI.KeyboardShortcut
public typealias PHEventModifiers = SwiftUI.EventModifiers
public typealias PHKeyPress = SwiftUI.KeyPress
public typealias PHDragGesture = SwiftUI.DragGesture
public typealias PHDropInfo = SwiftUI.DropInfo
public typealias PHDropProposal = SwiftUI.DropProposal
public typealias PHDropDelegate = SwiftUI.DropDelegate
public typealias PHOpenURLAction = SwiftUI.OpenURLAction

// MARK: Drawing

public typealias PHColor = SwiftUI.Color
public typealias PHFont = SwiftUI.Font
public typealias PHColorScheme = SwiftUI.ColorScheme
public typealias PHShape = SwiftUI.Shape
public typealias PHInsettableShape = SwiftUI.InsettableShape
public typealias PHAnyShape = SwiftUI.AnyShape
public typealias PHShapeStyle = SwiftUI.ShapeStyle
public typealias PHAnyShapeStyle = SwiftUI.AnyShapeStyle
public typealias PHRectangle = SwiftUI.Rectangle
public typealias PHRoundedRectangle = SwiftUI.RoundedRectangle
public typealias PHUnevenRoundedRectangle = SwiftUI.UnevenRoundedRectangle
public typealias PHCircle = SwiftUI.Circle
public typealias PHCapsule = SwiftUI.Capsule
public typealias PHPath = SwiftUI.Path
public typealias PHStrokeStyle = SwiftUI.StrokeStyle
public typealias PHLinearGradient = SwiftUI.LinearGradient
public typealias PHGradient = SwiftUI.Gradient
public typealias PHAnimation = SwiftUI.Animation
public typealias PHAnimatable = SwiftUI.Animatable

// MARK: State and environment

public typealias PHState<Value> = SwiftUI.State<Value>
public typealias PHBinding<Value> = SwiftUI.Binding<Value>
public typealias PHBindable<Value> = SwiftUI.Bindable<Value>
public typealias PHEnvironment<Value> = SwiftUI.Environment<Value>
public typealias PHEnvironmentValues = SwiftUI.EnvironmentValues
public typealias PHEnvironmentKey = SwiftUI.EnvironmentKey
public typealias PHFocusState<Value: Hashable> = SwiftUI.FocusState<Value>
public typealias PHAppStorage<Value> = SwiftUI.AppStorage<Value>
public typealias PHNamespace = SwiftUI.Namespace

/// Runs `body`, animating the view changes it causes.
@discardableResult
public func phWithAnimation<Result>(_ animation: PHAnimation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(animation, body)
}
#endif
