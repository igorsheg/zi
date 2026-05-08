const buffer = @import("buffer.zig");
const view = @import("view.zig");
const layout = @import("layout.zig");
const navigation = @import("navigation.zig");
const autocomplete = @import("autocomplete.zig");
const render = @import("render.zig");
const types = @import("types.zig");
pub const interface = @import("interface.zig");

pub const EditBuffer = buffer.EditBuffer;
pub const TextAreaView = view.TextAreaView;
pub const TextAreaLayoutCache = layout.TextAreaLayoutCache;
pub const AutocompleteSession = autocomplete.AutocompleteSession;
pub const AutocompleteInputOutcome = autocomplete.InputOutcome;
pub const renderVisibleLines = render.renderVisibleLines;
pub const RenderConfig = render.RenderConfig;
pub const moveVisual = navigation.moveVisual;

pub const LogicalCursor = types.LogicalCursor;
pub const VisualCursor = types.VisualCursor;
pub const Viewport = types.Viewport;
pub const VirtualLine = types.VirtualLine;
pub const VirtualLineKind = types.VirtualLineKind;
pub const LayoutConfig = types.LayoutConfig;
