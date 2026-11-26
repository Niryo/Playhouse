// Raw-GTK helpers both demos share. Every widget parameter is a GtkWidget*
// passed as void*, so this header never includes GTK and never clashes with a
// UI library's own GTK module. Output is JSON lines on stdout prefixed "PERF ".
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Loads an application-wide stylesheet (GTK_STYLE_PROVIDER_PRIORITY_USER).
void ph_load_css(const char *css);
/// Asks GTK for the dark variant of the theme.
void ph_prefer_dark(void);
void ph_add_css_class(void *widget, const char *css_class);
/// gtk_widget_set_can_target: whether the widget (and its children) receive pointer events.
void ph_set_can_target(void *widget, int can_target);
/// Sets a GtkOrientable (level bar, box, …) vertical.
void ph_set_vertical(void *widget);
void ph_set_css_class(void *widget, const char *css_class, int on);

/// The first descendant (depth first, including `root`) carrying `css_class`, or NULL.
void *ph_find_by_class(void *root, const char *css_class);
/// Number of GtkLabels under `root` whose text contains `text` (visible ones only).
int ph_count_labels(void *root, const char *text);
/// The toplevel GtkWindow of `widget`, or NULL.
void *ph_window_of(void *widget);
/// The content of a GtkWindow (gtk_window_get_child), without client-side decorations.
void *ph_window_child(void *window);
/// The first realized toplevel window of the default display, or NULL.
void *ph_first_toplevel(void);

/// Starts recording frames of `window`'s frame clock. Prints the first frame
/// and the first frame whose scrollable content is at least `min_content_px`
/// tall, in ms since `t0_us` (g_get_real_time() clock; 0 = process start).
void ph_probe_attach(void *window, long long t0_us, double min_content_px);
/// Attaches the probe to the first toplevel window as soon as it is realized
/// (a GTK emission hook), so no UI library has to hand its window over.
void ph_probe_install(long long t0_us, double min_content_px);
/// The probed window, once realized; NULL before.
void *ph_probe_window(void);
/// Calls `callback(context)` every `interval_ms` on the GLib main loop until it returns 0.
unsigned ph_timeout_add(unsigned interval_ms, int (*callback)(void *context), void *context);
/// Whether the first frame / the content frame have been painted.
int ph_probe_first_frame_done(void);
int ph_probe_content_frame_done(void);
/// Clears the frame statistics.
void ph_probe_reset(void);
/// Marks a model update; the next frame's end records update latency.
void ph_probe_mark(void);
/// Prints frame interval / frame work / update latency statistics under `label`.
void ph_probe_report(const char *label);

/// Scrolls the first GtkScrolledWindow under `window` to the end and back at
/// `px_per_frame`, recording frames, then reports "scroll" and calls `done`.
void ph_probe_scroll(void *window, double px_per_frame, void (*done)(void));

/// Renders `widget` (state included, e.g. hover) to a PNG at `scale`.
int ph_snapshot_png(void *widget, const char *path, double scale);

/// Calls `callback(context, x, y)` on a secondary (right) click on `widget`.
void ph_on_secondary_click(void *widget, void (*callback)(void *context, double x, double y), void *context);
/// Calls `callback(context, entered)` when the pointer enters/leaves `widget`.
void ph_on_hover(void *widget, void (*callback)(void *context, int entered), void *context);

/// A context menu (GtkPopoverMenu) attached to `widget`; item `i` calls
/// `callback(context, i)`. Destructive items get the "destructive" style.
void *ph_context_menu_new(void *widget, const char *const *titles, const int *destructive, int count,
                          void (*callback)(void *context, int index), void *context);
void ph_context_menu_popup(void *menu, double x, double y);

/// Prints the widget chain gtk_widget_pick finds at window coordinates (x, y).
void ph_debug_pick(void *window, double x, double y);
/// fflush(stdout), which Swift 6 code cannot reference directly.
void ph_flush(void);
/// Resident set size and its peak, in KiB, from /proc/self/status.
long ph_rss_kb(void);
long ph_hwm_kb(void);
/// User + system CPU seconds of this process.
double ph_cpu_seconds(void);
/// Monotonic microseconds (g_get_monotonic_time) and wall-clock microseconds.
long long ph_now_us(void);
long long ph_real_us(void);

void ph_set_overflow_hidden(void *widget);

#ifdef __cplusplus
}
#endif
