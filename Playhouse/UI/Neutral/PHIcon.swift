/// The icons Playhouse draws, by its own names. Views ask for a `PHIcon`, never a platform's
/// symbol name: on macOS each maps to an SF Symbol (`sfSymbolName`), and a Linux build maps it
/// to an icon of the GTK icon theme (`iconThemeName`).
public enum PHIcon: Hashable, Sendable {
    case archivebox
    case arrowClockwise
    case arrowDown
    case arrowDownCircle
    case arrowDownRightAndArrowUpLeft
    case arrowDownToLine
    case arrowLeft
    case arrowTriangleTwoCirclepath
    case arrowTriangleBranch
    case arrowTriangleMerge
    case arrowTriangleSwap
    case arrowUp
    case arrowUpLeftAndArrowDownRight
    case arrowUturnBackward
    case arrowUturnBackwardCircle
    case bubbleLeftAndBubbleRight
    case bubbleLeftAndTextBubbleRight
    case chartBar
    case checklist
    case checklistChecked
    case checkmark
    case checkmarkCircle
    case checkmarkCircleFill
    case checkmarkSeal
    case chevronBackward
    case chevronDown
    case chevronLeft
    case chevronLeftForwardslashChevronRight
    case chevronRight
    case chevronUp
    case circle
    case circleDashed
    case circleFill
    case clock
    case clockArrowCirclepath
    case clockFill
    case command
    case docOnDoc
    case docTextMagnifyingglass
    case ellipsis
    case exclamationmarkTriangle
    case exclamationmarkTriangleFill
    case externaldriveBadgeExclamationmark
    case eye
    case eyeSlash
    case folder
    case folderBadgeGearshape
    case folderFill
    case gaugeOpenWithLinesNeedle33percentAndArrowtriangleFrom0percentTo50percent
    case gearshape
    case gearshapeTwo
    case gearshapeTwoFill
    case hammer
    case handRaisedFill
    case infoCircle
    case largecircleFillCircle
    case lightbulbMax
    case link
    case listBulletRectangle
    case lockFill
    case lockOpen
    case magnifyingglass
    case map
    case network
    case number
    case paperclip
    case pauseCircleFill
    case pencil
    case pencilLine
    case personTwo
    case personCropCircle
    case photo
    case playFill
    case plus
    case plusSquareDashed
    case puzzlepieceExtension
    case questionmark
    case `repeat`
    case scope
    case serverRack
    case sidebarLeft
    case sparkle
    case sparkles
    case squareAndPencil
    case squareDashed
    case squareDashedInsetFilled
    case squareOnSquare
    case stopFill
    case terminal
    case textBubble
    case textLineFirstAndArrowtriangleForward
    case trash
    case tray
    case wandAndStars
    case xmark
    case xmarkCircleFill
    /// An icon a plugin names. The plugin API names icons as SF Symbols; a known one reads as
    /// its case (`PHIcon(named:)`), any other is drawn by that name where the platform can.
    case named(String)

    /// The icon a plugin's SF Symbol name stands for.
    public init(named name: String) {
        self = Self.known[name] ?? .named(name)
    }

    private static let known: [String: PHIcon] = [
        "archivebox": .archivebox,
        "arrow.clockwise": .arrowClockwise,
        "arrow.down": .arrowDown,
        "arrow.down.circle": .arrowDownCircle,
        "arrow.down.right.and.arrow.up.left": .arrowDownRightAndArrowUpLeft,
        "arrow.down.to.line": .arrowDownToLine,
        "arrow.left": .arrowLeft,
        "arrow.triangle.2.circlepath": .arrowTriangleTwoCirclepath,
        "arrow.triangle.branch": .arrowTriangleBranch,
        "arrow.triangle.merge": .arrowTriangleMerge,
        "arrow.triangle.swap": .arrowTriangleSwap,
        "arrow.up": .arrowUp,
        "arrow.up.left.and.arrow.down.right": .arrowUpLeftAndArrowDownRight,
        "arrow.uturn.backward": .arrowUturnBackward,
        "arrow.uturn.backward.circle": .arrowUturnBackwardCircle,
        "bubble.left.and.bubble.right": .bubbleLeftAndBubbleRight,
        "bubble.left.and.text.bubble.right": .bubbleLeftAndTextBubbleRight,
        "chart.bar": .chartBar,
        "checklist": .checklist,
        "checklist.checked": .checklistChecked,
        "checkmark": .checkmark,
        "checkmark.circle": .checkmarkCircle,
        "checkmark.circle.fill": .checkmarkCircleFill,
        "checkmark.seal": .checkmarkSeal,
        "chevron.backward": .chevronBackward,
        "chevron.down": .chevronDown,
        "chevron.left": .chevronLeft,
        "chevron.left.forwardslash.chevron.right": .chevronLeftForwardslashChevronRight,
        "chevron.right": .chevronRight,
        "chevron.up": .chevronUp,
        "circle": .circle,
        "circle.dashed": .circleDashed,
        "circle.fill": .circleFill,
        "clock": .clock,
        "clock.arrow.circlepath": .clockArrowCirclepath,
        "clock.fill": .clockFill,
        "command": .command,
        "doc.on.doc": .docOnDoc,
        "doc.text.magnifyingglass": .docTextMagnifyingglass,
        "ellipsis": .ellipsis,
        "exclamationmark.triangle": .exclamationmarkTriangle,
        "exclamationmark.triangle.fill": .exclamationmarkTriangleFill,
        "externaldrive.badge.exclamationmark": .externaldriveBadgeExclamationmark,
        "eye": .eye,
        "eye.slash": .eyeSlash,
        "folder": .folder,
        "folder.badge.gearshape": .folderBadgeGearshape,
        "folder.fill": .folderFill,
        "gauge.open.with.lines.needle.33percent.and.arrowtriangle.from.0percent.to.50percent": .gaugeOpenWithLinesNeedle33percentAndArrowtriangleFrom0percentTo50percent,
        "gearshape": .gearshape,
        "gearshape.2": .gearshapeTwo,
        "gearshape.2.fill": .gearshapeTwoFill,
        "hammer": .hammer,
        "hand.raised.fill": .handRaisedFill,
        "info.circle": .infoCircle,
        "largecircle.fill.circle": .largecircleFillCircle,
        "lightbulb.max": .lightbulbMax,
        "link": .link,
        "list.bullet.rectangle": .listBulletRectangle,
        "lock.fill": .lockFill,
        "lock.open": .lockOpen,
        "magnifyingglass": .magnifyingglass,
        "map": .map,
        "network": .network,
        "number": .number,
        "paperclip": .paperclip,
        "pause.circle.fill": .pauseCircleFill,
        "pencil": .pencil,
        "pencil.line": .pencilLine,
        "person.2": .personTwo,
        "person.crop.circle": .personCropCircle,
        "photo": .photo,
        "play.fill": .playFill,
        "plus": .plus,
        "plus.square.dashed": .plusSquareDashed,
        "puzzlepiece.extension": .puzzlepieceExtension,
        "questionmark": .questionmark,
        "repeat": .repeat,
        "scope": .scope,
        "server.rack": .serverRack,
        "sidebar.left": .sidebarLeft,
        "sparkle": .sparkle,
        "sparkles": .sparkles,
        "square.and.pencil": .squareAndPencil,
        "square.dashed": .squareDashed,
        "square.dashed.inset.filled": .squareDashedInsetFilled,
        "square.on.square": .squareOnSquare,
        "stop.fill": .stopFill,
        "terminal": .terminal,
        "text.bubble": .textBubble,
        "text.line.first.and.arrowtriangle.forward": .textLineFirstAndArrowtriangleForward,
        "trash": .trash,
        "tray": .tray,
        "wand.and.stars": .wandAndStars,
        "xmark": .xmark,
        "xmark.circle.fill": .xmarkCircleFill,
    ]

    /// The icon's name in the plugin API, where icons are named as SF Symbols: what a native
    /// composite puts in an atom's props for this icon.
    public var name: String { sfSymbolName }

    /// The SF Symbol drawing this icon on Apple platforms.
    public var sfSymbolName: String {
        switch self {
        case .archivebox: "archivebox"
        case .arrowClockwise: "arrow.clockwise"
        case .arrowDown: "arrow.down"
        case .arrowDownCircle: "arrow.down.circle"
        case .arrowDownRightAndArrowUpLeft: "arrow.down.right.and.arrow.up.left"
        case .arrowDownToLine: "arrow.down.to.line"
        case .arrowLeft: "arrow.left"
        case .arrowTriangleTwoCirclepath: "arrow.triangle.2.circlepath"
        case .arrowTriangleBranch: "arrow.triangle.branch"
        case .arrowTriangleMerge: "arrow.triangle.merge"
        case .arrowTriangleSwap: "arrow.triangle.swap"
        case .arrowUp: "arrow.up"
        case .arrowUpLeftAndArrowDownRight: "arrow.up.left.and.arrow.down.right"
        case .arrowUturnBackward: "arrow.uturn.backward"
        case .arrowUturnBackwardCircle: "arrow.uturn.backward.circle"
        case .bubbleLeftAndBubbleRight: "bubble.left.and.bubble.right"
        case .bubbleLeftAndTextBubbleRight: "bubble.left.and.text.bubble.right"
        case .chartBar: "chart.bar"
        case .checklist: "checklist"
        case .checklistChecked: "checklist.checked"
        case .checkmark: "checkmark"
        case .checkmarkCircle: "checkmark.circle"
        case .checkmarkCircleFill: "checkmark.circle.fill"
        case .checkmarkSeal: "checkmark.seal"
        case .chevronBackward: "chevron.backward"
        case .chevronDown: "chevron.down"
        case .chevronLeft: "chevron.left"
        case .chevronLeftForwardslashChevronRight: "chevron.left.forwardslash.chevron.right"
        case .chevronRight: "chevron.right"
        case .chevronUp: "chevron.up"
        case .circle: "circle"
        case .circleDashed: "circle.dashed"
        case .circleFill: "circle.fill"
        case .clock: "clock"
        case .clockArrowCirclepath: "clock.arrow.circlepath"
        case .clockFill: "clock.fill"
        case .command: "command"
        case .docOnDoc: "doc.on.doc"
        case .docTextMagnifyingglass: "doc.text.magnifyingglass"
        case .ellipsis: "ellipsis"
        case .exclamationmarkTriangle: "exclamationmark.triangle"
        case .exclamationmarkTriangleFill: "exclamationmark.triangle.fill"
        case .externaldriveBadgeExclamationmark: "externaldrive.badge.exclamationmark"
        case .eye: "eye"
        case .eyeSlash: "eye.slash"
        case .folder: "folder"
        case .folderBadgeGearshape: "folder.badge.gearshape"
        case .folderFill: "folder.fill"
        case .gaugeOpenWithLinesNeedle33percentAndArrowtriangleFrom0percentTo50percent: "gauge.open.with.lines.needle.33percent.and.arrowtriangle.from.0percent.to.50percent"
        case .gearshape: "gearshape"
        case .gearshapeTwo: "gearshape.2"
        case .gearshapeTwoFill: "gearshape.2.fill"
        case .hammer: "hammer"
        case .handRaisedFill: "hand.raised.fill"
        case .infoCircle: "info.circle"
        case .largecircleFillCircle: "largecircle.fill.circle"
        case .lightbulbMax: "lightbulb.max"
        case .link: "link"
        case .listBulletRectangle: "list.bullet.rectangle"
        case .lockFill: "lock.fill"
        case .lockOpen: "lock.open"
        case .magnifyingglass: "magnifyingglass"
        case .map: "map"
        case .network: "network"
        case .number: "number"
        case .paperclip: "paperclip"
        case .pauseCircleFill: "pause.circle.fill"
        case .pencil: "pencil"
        case .pencilLine: "pencil.line"
        case .personTwo: "person.2"
        case .personCropCircle: "person.crop.circle"
        case .photo: "photo"
        case .playFill: "play.fill"
        case .plus: "plus"
        case .plusSquareDashed: "plus.square.dashed"
        case .puzzlepieceExtension: "puzzlepiece.extension"
        case .questionmark: "questionmark"
        case .repeat: "repeat"
        case .scope: "scope"
        case .serverRack: "server.rack"
        case .sidebarLeft: "sidebar.left"
        case .sparkle: "sparkle"
        case .sparkles: "sparkles"
        case .squareAndPencil: "square.and.pencil"
        case .squareDashed: "square.dashed"
        case .squareDashedInsetFilled: "square.dashed.inset.filled"
        case .squareOnSquare: "square.on.square"
        case .stopFill: "stop.fill"
        case .terminal: "terminal"
        case .textBubble: "text.bubble"
        case .textLineFirstAndArrowtriangleForward: "text.line.first.and.arrowtriangle.forward"
        case .trash: "trash"
        case .tray: "tray"
        case .wandAndStars: "wand.and.stars"
        case .xmark: "xmark"
        case .xmarkCircleFill: "xmark.circle.fill"
        case .named(let name): name
        }
    }

    /// The icon theme name a GTK build draws, for the icons that have one; others fall back to
    /// `image-missing-symbolic` until the port adds them.
    public var iconThemeName: String {
        switch self {
        case .arrowClockwise: "view-refresh-symbolic"
        case .arrowDown: "go-down-symbolic"
        case .arrowLeft: "go-previous-symbolic"
        case .arrowUp: "go-up-symbolic"
        case .checkmark: "object-select-symbolic"
        case .chevronBackward: "go-previous-symbolic"
        case .chevronDown: "pan-down-symbolic"
        case .chevronLeft: "pan-start-symbolic"
        case .chevronRight: "pan-end-symbolic"
        case .chevronUp: "pan-up-symbolic"
        case .clock: "alarm-symbolic"
        case .docOnDoc: "edit-copy-symbolic"
        case .ellipsis: "view-more-symbolic"
        case .exclamationmarkTriangle: "dialog-warning-symbolic"
        case .exclamationmarkTriangleFill: "dialog-warning-symbolic"
        case .eye: "view-reveal-symbolic"
        case .eyeSlash: "view-conceal-symbolic"
        case .folder: "folder-symbolic"
        case .folderFill: "folder-symbolic"
        case .gearshape: "emblem-system-symbolic"
        case .infoCircle: "dialog-information-symbolic"
        case .link: "insert-link-symbolic"
        case .lockFill: "changes-prevent-symbolic"
        case .lockOpen: "changes-allow-symbolic"
        case .magnifyingglass: "system-search-symbolic"
        case .network: "network-workgroup-symbolic"
        case .paperclip: "mail-attachment-symbolic"
        case .pauseCircleFill: "media-playback-pause-symbolic"
        case .pencil: "document-edit-symbolic"
        case .pencilLine: "document-edit-symbolic"
        case .photo: "image-x-generic-symbolic"
        case .playFill: "media-playback-start-symbolic"
        case .plus: "list-add-symbolic"
        case .questionmark: "dialog-question-symbolic"
        case .repeat: "media-playlist-repeat-symbolic"
        case .sidebarLeft: "sidebar-show-symbolic"
        case .squareAndPencil: "document-edit-symbolic"
        case .stopFill: "media-playback-stop-symbolic"
        case .terminal: "utilities-terminal-symbolic"
        case .trash: "user-trash-symbolic"
        case .xmark: "window-close-symbolic"
        case .xmarkCircleFill: "window-close-symbolic"
        default: "image-missing-symbolic"
        }
    }
}
