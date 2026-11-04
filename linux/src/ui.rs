use crate::{
    model::{Activity, Session},
    monitor::{Monitor, ScanOptions, Snapshot},
    preferences::Preferences,
};
use adw::prelude::*;
use gtk::{gdk, gio, glib, pango};
use std::{
    cell::RefCell,
    path::PathBuf,
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

#[derive(Clone)]
pub struct Config {
    pub demo: bool,
    pub root: PathBuf,
    pub preferences: PathBuf,
    pub interval: f64,
    pub options: ScanOptions,
    pub size: (i32, i32),
    pub fullscreen: bool,
    pub monitor: Option<String>,
    pub list_monitors: bool,
    pub smoke_test: Option<PathBuf>,
}
#[derive(Clone)]
enum Action {
    Select(String),
    Back,
    Pin,
    Hide,
    Hidden,
    Restore,
    Page(i32),
    Scroll(bool),
    Fullscreen,
    Outputs,
}

fn label(text: &str, class: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.set_xalign(0.);
    l.add_css_class(class);
    l
}
fn wrap(l: &gtk::Label, lines: i32) {
    l.set_wrap(true);
    l.set_wrap_mode(pango::WrapMode::WordChar);
    l.set_lines(lines);
    l.set_ellipsize(pango::EllipsizeMode::End);
    l.set_max_width_chars(1);
}
fn button(text: &str, action: Action, tx: &mpsc::Sender<Action>) -> gtk::Button {
    let b = gtk::Button::with_label(text);
    b.add_css_class("touch");
    let tx = tx.clone();
    b.connect_clicked(move |_| {
        let _ = tx.send(action.clone());
    });
    b
}
fn margins(w: &impl IsA<gtk::Widget>, n: i32) {
    w.set_margin_start(n);
    w.set_margin_end(n);
    w.set_margin_top(n);
    w.set_margin_bottom(n);
}
fn age(time: f64) -> String {
    let seconds = (crate::now() - time).max(0.) as u64;
    if seconds < 60 {
        format!("{seconds}s ago")
    } else if seconds < 3600 {
        format!("{}m ago", seconds / 60)
    } else {
        format!("{}h ago", seconds / 3600)
    }
}

struct Card {
    button: gtk::Button,
    id: Rc<RefCell<String>>,
    project: gtk::Label,
    branch: gtk::Label,
    title: gtk::Label,
    state: gtk::Label,
    activity: gtk::Label,
    foot: gtk::Label,
}
impl Card {
    fn new(tx: &mpsc::Sender<Action>) -> Self {
        let button = gtk::Button::new();
        button.add_css_class("session-card");
        button.add_css_class("card");
        button.set_hexpand(true);
        button.set_vexpand(true);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 9);
        let project = label("", "heading");
        project.set_ellipsize(pango::EllipsizeMode::End);
        let branch = label("", "dim-label");
        branch.set_ellipsize(pango::EllipsizeMode::End);
        let title = label("", "title-2");
        wrap(&title, 2);
        let state = label("", "caption-heading");
        let activity = label("", "body");
        wrap(&activity, 2);
        activity.set_vexpand(true);
        activity.set_valign(gtk::Align::Start);
        let foot = label("", "dim-label");
        foot.set_ellipsize(pango::EllipsizeMode::End);
        for l in [&project, &branch, &title, &state, &activity, &foot] {
            content.append(l);
        }
        button.set_child(Some(&content));
        let id = Rc::new(RefCell::new(String::new()));
        let target = id.clone();
        let tx = tx.clone();
        button.connect_clicked(move |_| {
            let _ = tx.send(Action::Select(target.borrow().clone()));
        });
        Self {
            button,
            id,
            project,
            branch,
            title,
            state,
            activity,
            foot,
        }
    }
    fn update(&self, s: Option<&Session>, prefs: &Preferences) {
        let Some(s) = s else {
            self.button.set_visible(false);
            return;
        };
        self.button.set_visible(true);
        *self.id.borrow_mut() = s.id.clone();
        self.project.set_text(&format!(
            "{}{}",
            if prefs.pinned.contains(&s.id) {
                "★  "
            } else {
                ""
            },
            s.project_name()
        ));
        self.branch.set_text(if s.branch.is_empty() {
            "No recorded branch"
        } else {
            &s.branch
        });
        self.title.set_text(&s.heading().replace('\n', " "));
        self.state.set_text(&format!(
            "{}{}",
            s.state.to_uppercase(),
            if s.stale { " · STALE" } else { "" }
        ));
        for class in ["success", "warning", "error", "accent"] {
            self.state.remove_css_class(class);
        }
        self.state.add_css_class(if s.stale {
            "warning"
        } else {
            match s.state.as_str() {
                "working" => "accent",
                "completed" => "success",
                "error" => "error",
                _ => "warning",
            }
        });
        self.activity.set_text(if s.last_activity.is_empty() {
            "No recent activity recorded"
        } else {
            &s.last_activity
        });
        self.foot.set_text(&format!(
            "{}  ·  {}",
            age(s.updated_at),
            s.id.chars().take(8).collect::<String>()
        ));
        self.button
            .set_tooltip_text(Some(&format!("Open {}", s.heading())));
    }
}

struct Deck {
    window: adw::ApplicationWindow,
    title: adw::WindowTitle,
    stack: gtk::Stack,
    cards: Vec<Card>,
    empty: gtk::Label,
    detail_title: gtk::Label,
    summary: gtk::Label,
    summary_panel: gtk::ScrolledWindow,
    text: gtk::TextView,
    scroll: gtk::ScrolledWindow,
    pending: gtk::Label,
    notice: gtk::Label,
    page_label: gtk::Label,
    back: gtk::Button,
    pin: gtk::Button,
    hide: gtk::Button,
    hidden_button: gtk::Button,
    restore: gtk::Button,
    previous: gtk::Button,
    next: gtk::Button,
    fullscreen: gtk::Button,
    output: gtk::DropDown,
    outputs: Vec<gdk::Monitor>,
    requested_output: Option<String>,
    sessions: Vec<Session>,
    warnings: Vec<String>,
    prefs: Preferences,
    selected: Option<String>,
    hidden: bool,
    page: usize,
    slots: usize,
    rendered_history: String,
    force_history: bool,
    demo: bool,
    display_warning: String,
    scan_options: Arc<Mutex<ScanOptions>>,
}
impl Deck {
    fn new(
        app: &adw::Application,
        config: &Config,
        tx: &mpsc::Sender<Action>,
        scan_options: Arc<Mutex<ScanOptions>>,
    ) -> Self {
        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("Codex Deck")
            .default_width(config.size.0)
            .default_height(config.size.1)
            .build();
        window.set_size_request(720, 400);
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::new();
        header.add_css_class("deck-header");
        let title = adw::WindowTitle::new("Codex Deck", "Existing local sessions");
        header.set_title_widget(Some(&title));
        let menu = gtk::MenuButton::builder()
            .icon_name("view-more-symbolic")
            .tooltip_text("Display options")
            .build();
        let popover = gtk::Popover::new();
        let options = gtk::Box::new(gtk::Orientation::Vertical, 12);
        margins(&options, 16);
        options.append(&label("Fullscreen display", "heading"));
        let output = gtk::DropDown::from_strings(&["Current display"]);
        output.set_tooltip_text(Some("Choose an already enabled display"));
        options.append(&output);
        let hint = label(
            "Uses enabled displays. Configure rotation and touch in Linux Settings.",
            "dim-label",
        );
        wrap(&hint, 3);
        hint.set_size_request(270, -1);
        options.append(&hint);
        popover.set_child(Some(&options));
        menu.set_popover(Some(&popover));
        header.pack_end(&menu);
        toolbar.add_top_bar(&header);
        let body = gtk::Box::new(gtk::Orientation::Vertical, 8);
        margins(&body, 16);
        let stack = gtk::Stack::new();
        stack.set_vhomogeneous(false);
        stack.set_vexpand(true);
        stack.set_hexpand(true);
        let overview = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        overview.set_homogeneous(true);
        let cards: Vec<_> = (0..4).map(|_| Card::new(tx)).collect();
        for card in &cards {
            overview.append(&card.button);
        }
        let empty = label("Looking for existing Codex sessions…", "title-2");
        empty.set_hexpand(true);
        empty.set_xalign(0.5);
        wrap(&empty, 3);
        overview.append(&empty);
        stack.add_named(&overview, Some("overview"));
        let detail = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let detail_title = label("", "title-2");
        detail_title.set_ellipsize(pango::EllipsizeMode::End);
        detail.append(&detail_title);
        let detail_body = gtk::Box::new(gtk::Orientation::Horizontal, 20);
        detail_body.set_vexpand(true);
        let summary = label("", "dim-label");
        summary.set_selectable(true);
        summary.set_valign(gtk::Align::Start);
        summary.set_width_chars(28);
        summary.set_max_width_chars(28);
        summary.set_wrap(true);
        summary.set_wrap_mode(pango::WrapMode::WordChar);
        let summary_panel = gtk::ScrolledWindow::builder()
            .child(&summary)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .build();
        summary_panel.set_size_request(250, -1);
        detail_body.append(&summary_panel);
        let text = gtk::TextView::new();
        text.set_editable(false);
        text.set_cursor_visible(false);
        text.set_wrap_mode(gtk::WrapMode::WordChar);
        text.set_top_margin(12);
        text.set_bottom_margin(12);
        text.set_left_margin(16);
        text.set_right_margin(16);
        text.add_css_class("history");
        let scroll = gtk::ScrolledWindow::builder()
            .child(&text)
            .hexpand(true)
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        scroll.add_css_class("card");
        scroll.set_kinetic_scrolling(true);
        detail_body.append(&scroll);
        detail.append(&detail_body);
        let pending = label("Recent activity · newest first", "caption");
        detail.append(&pending);
        stack.add_named(&detail, Some("detail"));
        stack.set_visible_child_name("overview");
        body.append(&stack);
        let notice = label("", "caption");
        notice.set_ellipsize(pango::EllipsizeMode::End);
        body.append(&notice);
        toolbar.set_content(Some(&body));
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        margins(&footer, 8);
        let back = button("Back", Action::Back, tx);
        let pin = button("Pin", Action::Pin, tx);
        let hide = button("Hide", Action::Hide, tx);
        let hidden_button = button("Hidden", Action::Hidden, tx);
        let restore = button("Restore all", Action::Restore, tx);
        let previous = button("Previous", Action::Page(-1), tx);
        let next = button("Next", Action::Page(1), tx);
        let page_label = label("", "dim-label");
        page_label.set_hexpand(true);
        page_label.set_xalign(0.5);
        let fullscreen = button("Fullscreen", Action::Fullscreen, tx);
        for b in [&back, &pin, &hide, &hidden_button, &restore, &previous] {
            footer.append(b);
        }
        footer.append(&page_label);
        footer.append(&next);
        footer.append(&fullscreen);
        toolbar.add_bottom_bar(&footer);
        window.set_content(Some(&toolbar));
        let keys = gtk::EventControllerKey::new();
        let key_tx = tx.clone();
        let key_stack = stack.clone();
        keys.connect_key_pressed(move |_, key, _, _| {
            let action = match key {
                gdk::Key::Escape => Some(Action::Back),
                gdk::Key::F11 => Some(Action::Fullscreen),
                gdk::Key::Left if key_stack.visible_child_name().as_deref() == Some("overview") => {
                    Some(Action::Page(-1))
                }
                gdk::Key::Right
                    if key_stack.visible_child_name().as_deref() == Some("overview") =>
                {
                    Some(Action::Page(1))
                }
                _ => None,
            };
            if let Some(a) = action {
                let _ = key_tx.send(a);
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        window.add_controller(keys);
        // Claim horizontal drags before the child button can activate on release.
        let drag = gtk::GestureDrag::new();
        drag.set_touch_only(true);
        drag.set_propagation_phase(gtk::PropagationPhase::Capture);
        drag.connect_drag_update(|g, x, y| {
            if x.abs() > 40. && x.abs() > y.abs() * 1.5 {
                g.set_state(gtk::EventSequenceState::Claimed);
            }
        });
        let swipe_tx = tx.clone();
        drag.connect_drag_end(move |_, x, y| {
            if x.abs() > 80. && x.abs() > y.abs() * 1.5 {
                let _ = swipe_tx.send(Action::Page(if x < 0. { 1 } else { -1 }));
            }
        });
        overview.add_controller(drag);
        let model = gtk::prelude::WidgetExt::display(&window).monitors();
        let outputs_tx = tx.clone();
        model.connect_items_changed(move |_, _, _, _| {
            let _ = outputs_tx.send(Action::Outputs);
        });
        let prefs = Preferences::load(if config.demo {
            None
        } else {
            Some(config.preferences.clone())
        });
        scan_options.lock().unwrap().preferred_ids = prefs.pinned.clone();
        let mut deck = Self {
            window,
            title,
            stack,
            cards,
            empty,
            detail_title,
            summary,
            summary_panel,
            text,
            scroll,
            pending,
            notice,
            page_label,
            back,
            pin,
            hide,
            hidden_button,
            restore,
            previous,
            next,
            fullscreen,
            output,
            outputs: vec![],
            requested_output: config.monitor.clone(),
            sessions: if config.demo { demo_sessions() } else { vec![] },
            warnings: vec![],
            prefs,
            selected: None,
            hidden: false,
            page: 0,
            slots: 4,
            rendered_history: String::new(),
            force_history: true,
            demo: config.demo,
            display_warning: String::new(),
            scan_options,
        };
        deck.refresh_outputs(true);
        deck.render();
        deck
    }
    fn refresh_outputs(&mut self, initial: bool) {
        let previous = self
            .output
            .selected()
            .checked_sub(1)
            .and_then(|i| self.outputs.get(i as usize))
            .and_then(|m| m.connector())
            .map(|s| s.to_string())
            .or_else(|| {
                if initial || self.output.selected() as usize > self.outputs.len() {
                    self.requested_output.clone()
                } else {
                    None
                }
            });
        self.outputs = monitors(&gtk::prelude::WidgetExt::display(&self.window));
        let mut names = vec!["Current display".to_string()];
        names.extend(self.outputs.iter().map(|m| {
            format!(
                "{} · {}",
                m.connector().as_deref().unwrap_or("Display"),
                m.model().as_deref().unwrap_or("Unknown")
            )
        }));
        let index = previous.as_ref().and_then(|name| {
            self.outputs
                .iter()
                .position(|m| m.connector().as_deref() == Some(name.as_str()))
        });
        let selected = if let Some(i) = index {
            self.requested_output = None;
            i as u32 + 1
        } else if let Some(name) = previous {
            names.push(format!("{name} (unavailable)"));
            self.requested_output = Some(name.clone());
            self.window.unfullscreen();
            self.display_warning = format!(
                "Display {name} is unavailable. Choose an enabled display in Display options."
            );
            names.len() as u32 - 1
        } else {
            0
        };
        let refs: Vec<_> = names.iter().map(String::as_str).collect();
        self.output.set_model(Some(&gtk::StringList::new(&refs)));
        self.output.set_selected(selected);
    }
    fn toggle_fullscreen(&mut self) {
        if self.window.is_fullscreen() {
            self.window.unfullscreen();
            return;
        }
        let selected = self.output.selected();
        if selected == 0 {
            self.requested_output = None;
            self.display_warning.clear();
            self.window.fullscreen();
        } else if let Some(m) = self.outputs.get(selected as usize - 1) {
            self.requested_output = None;
            self.display_warning.clear();
            self.window.fullscreen_on_monitor(m);
        } else {
            self.display_warning =
                "Selected display is unavailable; choose an enabled display in Display options."
                    .into();
        }
    }
    fn act(&mut self, action: Action) {
        match action {
            Action::Select(id) => {
                if self.sessions.iter().any(|s| s.id == id) {
                    self.selected = Some(id);
                    self.force_history = true;
                }
            }
            Action::Back => {
                if self.selected.take().is_none() {
                    if self.hidden {
                        self.hidden = false;
                        self.page = 0;
                    } else {
                        self.window.unfullscreen();
                    }
                }
            }
            Action::Pin | Action::Hide => {
                if let Some(id) = &self.selected {
                    self.prefs.toggle(
                        id,
                        if matches!(action, Action::Pin) {
                            "pinned"
                        } else {
                            "hidden"
                        },
                    );
                    self.scan_options.lock().unwrap().preferred_ids = self.prefs.pinned.clone();
                }
            }
            Action::Hidden => {
                self.hidden = !self.hidden;
                self.selected = None;
                self.page = 0;
            }
            Action::Restore => {
                self.prefs.restore_all();
            }
            Action::Page(delta) => {
                if self.selected.is_some() {
                    self.act(Action::Scroll(delta < 0));
                } else {
                    self.page = self.page.saturating_add_signed(delta as isize);
                }
            }
            Action::Scroll(newer) => {
                let a = self.scroll.vadjustment();
                if newer {
                    a.set_value(a.lower());
                    self.force_history = true;
                } else {
                    a.set_value(
                        (a.value() + a.page_size() * 0.8).min((a.upper() - a.page_size()).max(0.)),
                    );
                }
            }
            Action::Fullscreen => self.toggle_fullscreen(),
            Action::Outputs => self.refresh_outputs(false),
        }
        self.render();
    }
    fn render(&mut self) {
        let width = self.window.width().max(720);
        self.slots = (((width - 32) / 350) as usize).clamp(1, 4);
        if self
            .selected
            .as_ref()
            .is_some_and(|id| !self.sessions.iter().any(|s| &s.id == id))
        {
            self.selected = None;
        }
        let detail = self
            .selected
            .as_ref()
            .and_then(|id| self.sessions.iter().find(|s| &s.id == id));
        self.title.set_subtitle(if self.demo {
            "Synthetic preview · preferences stay in memory"
        } else {
            "Existing local sessions · observation only"
        });
        self.stack.set_visible_child_name(if detail.is_some() {
            "detail"
        } else {
            "overview"
        });
        self.back.set_visible(detail.is_some() || self.hidden);
        self.pin.set_visible(detail.is_some());
        self.hide.set_visible(detail.is_some());
        self.hidden_button
            .set_visible(detail.is_none() && !self.hidden);
        self.hidden_button
            .set_label(&format!("Hidden ({})", self.prefs.hidden.len()));
        self.restore.set_visible(detail.is_none() && self.hidden);
        self.restore.set_sensitive(!self.prefs.hidden.is_empty());
        self.fullscreen.set_label(if self.window.is_fullscreen() {
            "Windowed"
        } else {
            "Fullscreen"
        });
        if let Some(s) = detail {
            self.detail_title.set_text(&format!(
                "{} · {}",
                s.project_name(),
                s.heading().replace('\n', " ")
            ));
            self.summary_panel.set_visible(width >= 1000);
            if self.summary.selection_bounds().is_none() || self.force_history {
                self.summary.set_text(&format!(
                    "{}{}\nUpdated {}\n\n{}\n{}\n\n{}\n{} tokens\n{} primary limit\n\n{}",
                    s.state.to_uppercase(),
                    if s.stale { " · STALE" } else { "" },
                    age(s.updated_at),
                    s.project,
                    s.branch,
                    s.model,
                    s.total_tokens
                        .map(|n| n.to_string())
                        .unwrap_or_else(|| "Unknown".into()),
                    s.limit_used_percent
                        .map(|n| format!("{n}%"))
                        .unwrap_or_else(|| "Unknown".into()),
                    s.id
                ));
            }
            self.pin.set_label(if self.prefs.pinned.contains(&s.id) {
                "Unpin"
            } else {
                "Pin"
            });
            self.hide.set_label(if self.prefs.hidden.contains(&s.id) {
                "Show again"
            } else {
                "Hide"
            });
            let history = s.history();
            let a = self.scroll.vadjustment();
            let at_top = a.value() <= a.lower() + 2.;
            if self.force_history || (history != self.rendered_history && at_top) {
                self.text.buffer().set_text(&history);
                self.rendered_history = history.clone();
                a.set_value(a.lower());
                self.force_history = false;
            }
            self.pending.set_text(if history == self.rendered_history {
                "Recent activity · newest first"
            } else {
                "New activity · use Newer to return to the latest"
            });
            self.previous.set_label("Newer");
            self.next.set_label("Older");
            self.previous.set_sensitive(true);
            self.next.set_sensitive(true);
            self.page_label.set_text("");
        } else {
            let rows = self.prefs.visible(&self.sessions, self.hidden);
            let pages = rows.len().div_ceil(self.slots).max(1);
            self.page = self.page.min(pages - 1);
            for (i, card) in self.cards.iter().enumerate() {
                card.branch.set_visible(width >= 1000);
                card.update(
                    if i < self.slots {
                        rows.get(self.page * self.slots + i).copied()
                    } else {
                        None
                    },
                    &self.prefs,
                );
            }
            self.empty.set_visible(rows.is_empty());
            self.empty.set_text(if self.hidden {
                "No hidden sessions in the current scan"
            } else {
                "No recognizable Codex sessions found"
            });
            self.previous.set_label("Previous");
            self.next.set_label("Next");
            self.previous.set_sensitive(self.page > 0);
            self.next.set_sensitive(self.page + 1 < pages);
            self.page_label.set_text(&format!(
                "{}{} / {pages}",
                if self.hidden { "Hidden · " } else { "" },
                self.page + 1
            ));
        }
        let notice = if !self.prefs.warning.is_empty() {
            self.prefs.warning.clone()
        } else if !self.display_warning.is_empty() {
            self.display_warning.clone()
        } else if !self.warnings.is_empty() {
            self.warnings.join("  ")
        } else {
            "Stale = no recent file update. Recorded state does not prove a process is running."
                .into()
        };
        self.notice.set_text(&notice);
        self.notice.set_tooltip_text(Some(&notice));
    }
}
fn monitors(display: &gdk::Display) -> Vec<gdk::Monitor> {
    display
        .monitors()
        .iter::<gdk::Monitor>()
        .filter_map(Result::ok)
        .collect()
}

pub fn run(config: Config) -> u8 {
    if let Err(e) = adw::init() {
        eprintln!("Could not initialize GTK: {e}");
        return 1;
    }
    if config.list_monitors {
        if let Some(display) = gdk::Display::default() {
            for m in monitors(&display) {
                let r = m.geometry();
                println!(
                    "{}\t{}\t{}x{}\tscale {}",
                    m.connector().as_deref().unwrap_or("unknown"),
                    m.model().as_deref().unwrap_or("unknown"),
                    r.width(),
                    r.height(),
                    m.scale_factor()
                );
            }
        }
        return 0;
    }
    let provider = gtk::CssProvider::new();
    provider.load_from_string(include_str!("style.css"));
    gtk::style_context_add_provider_for_display(
        &gdk::Display::default().unwrap(),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    let app = adw::Application::builder()
        .application_id("io.github.georgemclaughlin.OpenAgentDeck")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.connect_activate(move |app| {
        let (tx, rx) = mpsc::channel();
        let (snapshot_tx, snapshot_rx) = mpsc::sync_channel::<Snapshot>(1);
        let scan_options = Arc::new(Mutex::new(config.options.clone()));
        let deck = Rc::new(RefCell::new(Deck::new(
            app,
            &config,
            &tx,
            scan_options.clone(),
        )));
        let alive = Arc::new(AtomicBool::new(true));
        let worker = if !config.demo {
            let alive = alive.clone();
            let root = config.root.clone();
            let interval = config.interval;
            Some(std::thread::spawn(move || {
                let mut monitor = Monitor::new(root);
                while alive.load(Ordering::Relaxed) {
                    let options = scan_options.lock().unwrap().clone();
                    let snapshot = monitor.snapshot(&options, crate::now());
                    let _ = snapshot_tx.try_send(snapshot);
                    std::thread::park_timeout(Duration::from_secs_f64(interval));
                }
            }))
        } else {
            None
        };
        let closing = alive.clone();
        deck.borrow().window.connect_close_request(move |_| {
            closing.store(false, Ordering::Relaxed);
            if let Some(worker) = &worker {
                worker.thread().unpark();
            }
            glib::Propagation::Proceed
        });
        deck.borrow().window.present();
        if config.fullscreen {
            deck.borrow_mut().toggle_fullscreen();
        }
        let mut last_render = Instant::now();
        let mut last_width = 0;
        let timer_deck = deck.clone();
        glib::timeout_add_local(Duration::from_millis(100), move || {
            if !alive.load(Ordering::Relaxed) {
                return glib::ControlFlow::Break;
            }
            let mut d = timer_deck.borrow_mut();
            while let Ok(a) = rx.try_recv() {
                d.act(a);
            }
            let mut changed = false;
            while let Ok(snapshot) = snapshot_rx.try_recv() {
                d.sessions = snapshot.sessions;
                d.warnings = snapshot.warnings;
                changed = true;
            }
            let width = d.window.width();
            if changed || width != last_width || last_render.elapsed() >= Duration::from_secs(1) {
                d.render();
                last_render = Instant::now();
                last_width = width;
            }
            glib::ControlFlow::Continue
        });
        if let Some(path) = &config.smoke_test {
            smoke::run(deck, path.clone());
        }
    });
    app.run_with_args::<&str>(&[]).into()
}

pub fn demo_sessions() -> Vec<Session> {
    let projects = [
        "openagentdeck",
        "website",
        "data-pipeline",
        "api-service",
        "documentation",
    ];
    let titles = [
        "Build a native Linux session deck",
        "Fix the mobile navigation layout",
        "Validate the import before rollout",
        "Investigate an intermittent timeout",
        "Update the getting started guide",
    ];
    let replies = [
        "The Rust monitor is connected. Building native touch controls next.",
        "Navigation now fits small screens. All checks passed.",
        "Import paused while the input format is checked.",
        "Waiting for the service to respond.",
        "The guide is ready for review.",
    ];
    projects
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let mut s = Session {
                id: format!("demo-{}", i + 1),
                project: format!("/projects/{p}"),
                title: titles[i].into(),
                branch: [
                    "feature/native-linux",
                    "fix/mobile-nav",
                    "main",
                    "fix/timeouts",
                    "docs/setup",
                ][i]
                    .into(),
                model: "demo-model".into(),
                state: ["working", "completed", "interrupted", "working", "unknown"][i].into(),
                updated_at: crate::now() - [5., 30., 70., 600., 900.][i],
                stale: i >= 3,
                total_tokens: Some(12400 + i as u64 * 3100),
                limit_used_percent: Some(28.),
                last_prompt: titles[i].into(),
                last_activity: replies[i].into(),
                ..Default::default()
            };
            s.recent = vec![
                Activity {
                    kind: "user".into(),
                    text: titles[i].into(),
                    timestamp: "10:42".into(),
                },
                Activity {
                    kind: "tool".into(),
                    text: "Command: completed (exit 0)".into(),
                    timestamp: "10:43".into(),
                },
                Activity {
                    kind: "assistant".into(),
                    text: replies[i].into(),
                    timestamp: "10:44".into(),
                },
            ];
            s
        })
        .collect()
}

#[path = "ui_smoke.rs"]
mod smoke;
