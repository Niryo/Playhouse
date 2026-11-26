#include "gtkprobe.h"

#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

// MARK: Styling

void ph_load_css(const char *css) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, css);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_USER);
    g_object_unref(provider);
}

void ph_prefer_dark(void) {
    g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", TRUE, NULL);
}

void ph_add_css_class(void *widget, const char *css_class) {
    if (widget) gtk_widget_add_css_class(GTK_WIDGET(widget), css_class);
}

void ph_set_can_target(void *widget, int can_target) {
    if (widget) gtk_widget_set_can_target(GTK_WIDGET(widget), can_target);
}

void ph_set_vertical(void *widget) {
    if (getenv("PH_DEBUG") && widget && GTK_IS_LEVEL_BAR(widget))
        printf("ph_set_vertical: value %f max %f inverted %d\n", gtk_level_bar_get_value(widget), gtk_level_bar_get_max_value(widget), gtk_level_bar_get_inverted(widget));
    if (widget && GTK_IS_ORIENTABLE(widget)) gtk_orientable_set_orientation(GTK_ORIENTABLE(widget), GTK_ORIENTATION_VERTICAL);
}

void ph_set_css_class(void *widget, const char *css_class, int on) {
    if (!widget) return;
    if (on) gtk_widget_add_css_class(GTK_WIDGET(widget), css_class);
    else gtk_widget_remove_css_class(GTK_WIDGET(widget), css_class);
}

void *ph_find_by_class(void *root, const char *css_class) {
    if (!root) return NULL;
    GtkWidget *widget = GTK_WIDGET(root);
    if (gtk_widget_has_css_class(widget, css_class)) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        void *found = ph_find_by_class(child, css_class);
        if (found) return found;
    }
    return NULL;
}

int ph_count_labels(void *root, const char *text) {
    if (!root) return 0;
    GtkWidget *widget = GTK_WIDGET(root);
    // Mapped, not just visible: a GtkStack keeps its hidden pages visible but unmapped.
    if (!gtk_widget_get_mapped(widget)) return 0;
    int count = 0;
    if (GTK_IS_LABEL(widget) && strstr(gtk_label_get_text(GTK_LABEL(widget)), text)) count++;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child))
        count += ph_count_labels(child, text);
    return count;
}

static GtkWidget *find_by_type(GtkWidget *widget, GType type) {
    if (G_TYPE_CHECK_INSTANCE_TYPE(widget, type)) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_by_type(child, type);
        if (found) return found;
    }
    return NULL;
}

void *ph_window_of(void *widget) {
    if (!widget) return NULL;
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(widget));
    return root && GTK_IS_WINDOW(root) ? root : NULL;
}

void *ph_window_child(void *window) {
    return window ? gtk_window_get_child(GTK_WINDOW(window)) : NULL;
}

void *ph_first_toplevel(void) {
    GListModel *toplevels = gtk_window_get_toplevels();
    guint count = g_list_model_get_n_items(toplevels);
    for (guint i = 0; i < count; i++) {
        GtkWidget *window = g_list_model_get_item(toplevels, i);
        g_object_unref(window);
        if (gtk_widget_get_realized(window) && !GTK_IS_POPOVER(window)) return window;
    }
    return NULL;
}

// MARK: Frame statistics

#define MAX_SAMPLES 200000

typedef struct {
    double *values;
    int count;
} Samples;

static Samples intervals, work, latency;
static gint64 frame_start_us, last_frame_end_us, mark_us, t0_real_us;
static double content_threshold;
static gboolean first_frame_done, content_frame_done;
static GtkWidget *probed_window;

static void samples_add(Samples *samples, double value) {
    if (!samples->values) samples->values = malloc(sizeof(double) * MAX_SAMPLES);
    if (samples->count < MAX_SAMPLES) samples->values[samples->count++] = value;
}

static int compare_doubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void samples_print(const char *name, Samples *samples) {
    if (samples->count == 0) {
        printf("\"%s\":{\"n\":0}", name);
        return;
    }
    qsort(samples->values, samples->count, sizeof(double), compare_doubles);
    double sum = 0;
    for (int i = 0; i < samples->count; i++) sum += samples->values[i];
    int n = samples->count;
    printf("\"%s\":{\"n\":%d,\"mean\":%.3f,\"median\":%.3f,\"p95\":%.3f,\"p99\":%.3f,\"max\":%.3f}", name, n, sum / n,
           samples->values[n / 2], samples->values[(int)(n * 0.95)], samples->values[(int)(n * 0.99)],
           samples->values[n - 1]);
}

static double content_height(void) {
    if (!probed_window) return 0;
    GtkWidget *scrolled = find_by_type(probed_window, GTK_TYPE_SCROLLED_WINDOW);
    if (!scrolled) return gtk_widget_get_height(probed_window);
    return gtk_adjustment_get_upper(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scrolled)));
}

static double since_t0_ms(void) {
    return (g_get_real_time() - t0_real_us) / 1000.0;
}

static void on_before_paint(GdkFrameClock *clock, gpointer data) {
    frame_start_us = g_get_monotonic_time();
}

static void on_after_paint(GdkFrameClock *clock, gpointer data) {
    gint64 now = g_get_monotonic_time();
    if (frame_start_us) samples_add(&work, (now - frame_start_us) / 1000.0);
    if (last_frame_end_us) samples_add(&intervals, (now - last_frame_end_us) / 1000.0);
    last_frame_end_us = now;
    if (mark_us) {
        samples_add(&latency, (now - mark_us) / 1000.0);
        mark_us = 0;
    }
    if (!first_frame_done) {
        first_frame_done = TRUE;
        printf("PERF {\"event\":\"first_frame\",\"ms\":%.1f,\"rss_kb\":%ld}\n", since_t0_ms(), ph_rss_kb());
        fflush(stdout);
    }
    if (!content_frame_done && content_height() >= content_threshold) {
        content_frame_done = TRUE;
        printf("PERF {\"event\":\"content_frame\",\"ms\":%.1f,\"content_px\":%.0f,\"rss_kb\":%ld}\n", since_t0_ms(),
               content_height(), ph_rss_kb());
        fflush(stdout);
    }
}

static void attach_clock(GtkWidget *window) {
    GdkFrameClock *clock = gtk_widget_get_frame_clock(window);
    if (!clock) return;
    g_signal_connect(clock, "before-paint", G_CALLBACK(on_before_paint), NULL);
    g_signal_connect(clock, "after-paint", G_CALLBACK(on_after_paint), NULL);
}

static void on_realize(GtkWidget *window, gpointer data) {
    attach_clock(window);
}

void ph_probe_attach(void *window, long long t0_us, double min_content_px) {
    if (!window || probed_window) return;
    probed_window = GTK_WIDGET(window);
    t0_real_us = t0_us;
    if (t0_real_us == 0) {
        // Process start time from /proc/self/stat (field 22, clock ticks since boot).
        FILE *stat = fopen("/proc/self/stat", "r");
        FILE *uptime = fopen("/proc/uptime", "r");
        unsigned long long start_ticks = 0;
        double up = 0;
        if (stat && uptime) {
            char buffer[1024];
            if (fgets(buffer, sizeof buffer, stat)) {
                char *p = strrchr(buffer, ')');
                for (int field = 2; p && field < 22; field++) p = strchr(p + 1, ' ');
                if (p) start_ticks = strtoull(p + 1, NULL, 10);
            }
            if (fscanf(uptime, "%lf", &up) != 1) up = 0;
        }
        if (stat) fclose(stat);
        if (uptime) fclose(uptime);
        double age = up - (double)start_ticks / sysconf(_SC_CLK_TCK);
        t0_real_us = g_get_real_time() - (gint64)(age * 1e6);
    }
    content_threshold = min_content_px;
    if (gtk_widget_get_realized(probed_window)) attach_clock(probed_window);
    else g_signal_connect(probed_window, "realize", G_CALLBACK(on_realize), NULL);
}

static gboolean realize_hook(GSignalInvocationHint *hint, guint n_params, const GValue *params, gpointer data) {
    GObject *object = g_value_get_object(&params[0]);
    if (probed_window) return FALSE;
    if (GTK_IS_WINDOW(object) && !GTK_IS_POPOVER(object)) {
        ph_probe_attach(object, t0_real_us, content_threshold);
        return FALSE;
    }
    return TRUE;
}

void ph_probe_install(long long t0_us, double min_content_px) {
    t0_real_us = t0_us;
    content_threshold = min_content_px;
    // Signals exist once the class is initialized, which gtk_init has not done yet.
    g_type_class_unref(g_type_class_ref(GTK_TYPE_WINDOW));
    guint signal = g_signal_lookup("realize", GTK_TYPE_WIDGET);
    g_signal_add_emission_hook(signal, 0, realize_hook, NULL, NULL);
}

void *ph_probe_window(void) {
    return probed_window;
}

typedef struct {
    int (*callback)(void *);
    void *context;
} Timeout;

static gboolean on_timeout(gpointer data) {
    Timeout *timeout = data;
    if (timeout->callback(timeout->context)) return G_SOURCE_CONTINUE;
    g_free(timeout);
    return G_SOURCE_REMOVE;
}

unsigned ph_timeout_add(unsigned interval_ms, int (*callback)(void *), void *context) {
    Timeout *timeout = g_new0(Timeout, 1);
    timeout->callback = callback;
    timeout->context = context;
    return g_timeout_add(interval_ms, on_timeout, timeout);
}

int ph_probe_first_frame_done(void) { return first_frame_done; }
int ph_probe_content_frame_done(void) { return content_frame_done; }

void ph_probe_reset(void) {
    intervals.count = work.count = latency.count = 0;
    last_frame_end_us = 0;
    mark_us = 0;
}

void ph_probe_mark(void) {
    if (!mark_us) mark_us = g_get_monotonic_time();
}

void ph_probe_report(const char *label) {
    printf("PERF {\"event\":\"%s\",", label);
    samples_print("interval_ms", &intervals);
    printf(",");
    samples_print("work_ms", &work);
    printf(",");
    samples_print("latency_ms", &latency);
    printf(",\"rss_kb\":%ld,\"hwm_kb\":%ld,\"cpu_s\":%.3f}\n", ph_rss_kb(), ph_hwm_kb(), ph_cpu_seconds());
    fflush(stdout);
}

// MARK: Scroll benchmark

typedef struct {
    GtkAdjustment *adjustment;
    double step;
    int direction;
    void (*done)(void);
} ScrollRun;

static gboolean scroll_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    ScrollRun *run = data;
    double value = gtk_adjustment_get_value(run->adjustment);
    double limit = gtk_adjustment_get_upper(run->adjustment) - gtk_adjustment_get_page_size(run->adjustment);
    value += run->step * run->direction;
    if (run->direction > 0 && value >= limit) {
        value = limit;
        run->direction = -1;
    } else if (run->direction < 0 && value <= 0) {
        gtk_adjustment_set_value(run->adjustment, 0);
        ph_probe_report("scroll");
        if (run->done) run->done();
        free(run);
        return G_SOURCE_REMOVE;
    }
    gtk_adjustment_set_value(run->adjustment, value);
    return G_SOURCE_CONTINUE;
}

void ph_probe_scroll(void *window, double px_per_frame, void (*done)(void)) {
    GtkWidget *scrolled = window ? find_by_type(GTK_WIDGET(window), GTK_TYPE_SCROLLED_WINDOW) : NULL;
    if (!scrolled) {
        printf("PERF {\"event\":\"scroll\",\"error\":\"no GtkScrolledWindow\"}\n");
        fflush(stdout);
        if (done) done();
        return;
    }
    ScrollRun *run = calloc(1, sizeof(ScrollRun));
    run->adjustment = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scrolled));
    run->step = px_per_frame;
    run->direction = 1;
    run->done = done;
    ph_probe_reset();
    gtk_widget_add_tick_callback(scrolled, scroll_tick, run, NULL);
}

// MARK: Snapshot

static void debug_tree(GtkWidget *widget, int depth) {
    if (GTK_IS_LEVEL_BAR(widget))
        printf("debug: levelbar value %f inverted %d vertical %d h=%d w=%d\n", gtk_level_bar_get_value(GTK_LEVEL_BAR(widget)),
               gtk_level_bar_get_inverted(GTK_LEVEL_BAR(widget)),
               gtk_orientable_get_orientation(GTK_ORIENTABLE(widget)) == GTK_ORIENTATION_VERTICAL,
               gtk_widget_get_height(widget), gtk_widget_get_width(widget));
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child))
        debug_tree(child, depth + 1);
}

int ph_snapshot_png(void *widget_pointer, const char *path, double scale) {
    if (!widget_pointer) return 0;
    if (getenv("PH_DEBUG")) debug_tree(GTK_WIDGET(ph_probe_window()), 0);
    GtkWidget *widget = GTK_WIDGET(widget_pointer);
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    if (width <= 0 || height <= 0) return 0;
    GdkPaintable *paintable = gtk_widget_paintable_new(widget);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gtk_snapshot_scale(snapshot, scale, scale);
    gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot), width, height);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    int ok = 0;
    if (node) {
        GskRenderer *renderer = gtk_native_get_renderer(gtk_widget_get_native(widget));
        graphene_rect_t viewport = GRAPHENE_RECT_INIT(0, 0, width * scale, height * scale);
        GdkTexture *texture = gsk_renderer_render_texture(renderer, node, &viewport);
        ok = gdk_texture_save_to_png(texture, path);
        g_object_unref(texture);
        gsk_render_node_unref(node);
    }
    g_object_unref(paintable);
    return ok;
}

// MARK: Input

typedef struct {
    void (*callback)(void *, double, double);
    void *context;
} ClickHandler;

static void on_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    ClickHandler *handler = data;
    handler->callback(handler->context, x, y);
}

void ph_on_secondary_click(void *widget, void (*callback)(void *, double, double), void *context) {
    if (!widget) return;
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(gesture), GDK_BUTTON_SECONDARY);
    ClickHandler *handler = g_new0(ClickHandler, 1);
    handler->callback = callback;
    handler->context = context;
    g_signal_connect_data(gesture, "pressed", G_CALLBACK(on_pressed), handler, (GClosureNotify)g_free, 0);
    gtk_widget_add_controller(GTK_WIDGET(widget), GTK_EVENT_CONTROLLER(gesture));
}

typedef struct {
    void (*callback)(void *, int);
    void *context;
} HoverHandler;

static void on_enter(GtkEventControllerMotion *motion, double x, double y, gpointer data) {
    HoverHandler *handler = data;
    handler->callback(handler->context, 1);
}

static void on_leave(GtkEventControllerMotion *motion, gpointer data) {
    HoverHandler *handler = data;
    handler->callback(handler->context, 0);
}

void ph_on_hover(void *widget, void (*callback)(void *, int), void *context) {
    if (!widget) return;
    GtkEventController *motion = gtk_event_controller_motion_new();
    HoverHandler *handler = g_new0(HoverHandler, 1);
    handler->callback = callback;
    handler->context = context;
    g_signal_connect(motion, "enter", G_CALLBACK(on_enter), handler);
    g_signal_connect_data(motion, "leave", G_CALLBACK(on_leave), handler, (GClosureNotify)g_free, 0);
    gtk_widget_add_controller(GTK_WIDGET(widget), motion);
}

// MARK: Context menu

typedef struct {
    void (*callback)(void *, int);
    void *context;
    int index;
} MenuAction;

static void on_menu_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    MenuAction *menu_action = data;
    menu_action->callback(menu_action->context, menu_action->index);
}

void *ph_context_menu_new(void *widget, const char *const *titles, const int *destructive, int count,
                          void (*callback)(void *, int), void *context) {
    if (!widget) return NULL;
    GMenu *menu = g_menu_new();
    GMenu *section = g_menu_new();
    GSimpleActionGroup *group = g_simple_action_group_new();
    for (int i = 0; i < count; i++) {
        char name[32], detailed[48];
        snprintf(name, sizeof name, "item%d", i);
        snprintf(detailed, sizeof detailed, "phcard.item%d", i);
        // The destructive item goes in its own section, as the macOS menu separates it.
        if (destructive && destructive[i] && g_menu_model_get_n_items(G_MENU_MODEL(section)) > 0) {
            g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
            g_object_unref(section);
            section = g_menu_new();
        }
        g_menu_append(section, titles[i], detailed);
        GSimpleAction *action = g_simple_action_new(name, NULL);
        MenuAction *menu_action = g_new0(MenuAction, 1);
        menu_action->callback = callback;
        menu_action->context = context;
        menu_action->index = i;
        g_signal_connect_data(action, "activate", G_CALLBACK(on_menu_action), menu_action, (GClosureNotify)g_free, 0);
        g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
        g_object_unref(action);
    }
    g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
    g_object_unref(section);
    gtk_widget_insert_action_group(GTK_WIDGET(widget), "phcard", G_ACTION_GROUP(group));
    g_object_unref(group);
    GtkWidget *popover = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
    g_object_unref(menu);
    gtk_widget_set_parent(popover, GTK_WIDGET(widget));
    gtk_popover_set_has_arrow(GTK_POPOVER(popover), FALSE);
    gtk_widget_set_halign(popover, GTK_ALIGN_START);
    gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
    return popover;
}

void ph_context_menu_popup(void *menu, double x, double y) {
    if (!menu) return;
    GdkRectangle rect = {(int)x, (int)y, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(menu), &rect);
    gtk_popover_popup(GTK_POPOVER(menu));
}

// MARK: Process metrics

static long status_kb(const char *key) {
    FILE *file = fopen("/proc/self/status", "r");
    if (!file) return -1;
    char line[256];
    long value = -1;
    size_t length = strlen(key);
    while (fgets(line, sizeof line, file)) {
        if (strncmp(line, key, length) == 0) {
            value = strtol(line + length, NULL, 10);
            break;
        }
    }
    fclose(file);
    return value;
}

void ph_debug_pick(void *window, double x, double y) {
    GtkWidget *picked = gtk_widget_pick(GTK_WIDGET(window), x, y, GTK_PICK_DEFAULT);
    printf("pick(%.0f,%.0f):", x, y);
    for (GtkWidget *w = picked; w; w = gtk_widget_get_parent(w)) {
        graphene_rect_t b;
        if (gtk_widget_compute_bounds(w, GTK_WIDGET(window), &b))
            printf(" %s[%.0f,%.0f %.0fx%.0f]", G_OBJECT_TYPE_NAME(w), b.origin.x, b.origin.y, b.size.width, b.size.height);
        if (GTK_IS_WINDOW(w)) break;
    }
    printf("\n");
    fflush(stdout);
}

void ph_flush(void) { fflush(stdout); }

long ph_rss_kb(void) { return status_kb("VmRSS:"); }
long ph_hwm_kb(void) { return status_kb("VmHWM:"); }

double ph_cpu_seconds(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

long long ph_now_us(void) { return g_get_monotonic_time(); }
long long ph_real_us(void) { return g_get_real_time(); }

/* Clips a widget's children to its allocation (the SwiftCrossUI fork's
   animated card clips the expanding section while its height grows). */
void ph_set_overflow_hidden(void *widget) {
    gtk_widget_set_overflow(GTK_WIDGET(widget), GTK_OVERFLOW_HIDDEN);
}
