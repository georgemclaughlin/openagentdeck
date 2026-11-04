// Synthetic native-widget checks, invoked only with --demo --smoke-test.
use super::*;

fn capture(deck: &Deck, path: &std::path::Path) {
    use gtk::gsk::prelude::*;
    let paintable = gtk::WidgetPaintable::new(Some(&deck.window));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(
        &snapshot,
        deck.window.width() as f64,
        deck.window.height() as f64,
    );
    let node = snapshot.to_node().expect("window has a render node");
    let viewport = gtk::graphene::Rect::new(
        0.,
        0.,
        deck.window.width() as f32,
        deck.window.height() as f32,
    );
    let texture = deck
        .window
        .renderer()
        .unwrap()
        .render_texture(&node, Some(&viewport));
    texture.save_to_png(path).expect("write synthetic preview");
}
pub(super) fn run(deck: Rc<RefCell<Deck>>, path: PathBuf) {
    std::fs::create_dir_all(&path).unwrap();
    let mut step = 0;
    glib::timeout_add_local(Duration::from_millis(500), move || {
        let mut d = deck.borrow_mut();
        match step {
            0 => {
                assert_eq!(d.slots, 4);
                assert_eq!(d.cards.iter().filter(|c| c.button.is_visible()).count(), 4);
                assert!(d.next.height() >= 56);
                assert!(d.cards[0].button.height() >= 180);
                capture(&d, &path.join("overview.png"));
                d.cards[0].button.emit_clicked();
            }
            1 => {
                assert_eq!(d.selected.as_deref(), Some("demo-1"));
                assert!(!d.text.is_editable());
                assert!(d.rendered_history.starts_with("ASSISTANT"));
                capture(&d, &path.join("details.png"));
                d.pin.emit_clicked();
            }
            2 => {
                assert!(d.prefs.pinned.contains("demo-1"));
                d.hide.emit_clicked();
            }
            3 => {
                assert!(d.prefs.hidden.contains("demo-1"));
                d.back.emit_clicked();
            }
            4 => {
                assert!(d.selected.is_none());
                assert!(
                    !d.cards
                        .iter()
                        .any(|c| c.button.is_visible() && *c.id.borrow() == "demo-1")
                );
                d.hidden_button.emit_clicked();
            }
            5 => {
                assert!(d.hidden);
                assert_eq!(*d.cards[0].id.borrow(), "demo-1");
                d.cards[0].button.emit_clicked();
            }
            6 => {
                assert_eq!(d.hide.label().as_deref(), Some("Show again"));
                d.hide.emit_clicked();
            }
            7 => {
                assert!(!d.prefs.hidden.contains("demo-1"));
                d.prefs.toggle("outside-scan", "hidden");
                d.act(Action::Restore);
                assert!(d.prefs.hidden.is_empty());
                let s = d.sessions.iter_mut().find(|s| s.id == "demo-1").unwrap();
                for i in 0..12 {
                    s.add(
                        "assistant",
                        &format!(
                            "Earlier update {i}\n{}",
                            "A synthetic history line.\n".repeat(10)
                        ),
                        &serde_json::Value::Null,
                    );
                }
                d.force_history = true;
                d.render();
            }
            8 => {
                d.next.emit_clicked();
            }
            9 => {
                assert!(d.scroll.vadjustment().value() > 2.);
                let before = d.rendered_history.clone();
                let position = d.scroll.vadjustment().value();
                d.sessions
                    .iter_mut()
                    .find(|s| s.id == "demo-1")
                    .unwrap()
                    .add("assistant", "Newest update", &serde_json::Value::Null);
                d.render();
                assert_eq!(d.rendered_history, before);
                assert_eq!(d.scroll.vadjustment().value(), position);
                assert!(d.pending.text().starts_with("New activity"));
                d.previous.emit_clicked();
            }
            10 => {
                assert!(d.rendered_history.contains("Newest update"));
                assert!(d.scroll.vadjustment().value() <= 2.);
                d.sessions.reverse();
                d.render();
                assert_eq!(d.selected.as_deref(), Some("demo-1"));
                d.window.set_default_size(800, 400);
            }
            11 => {
                assert!(!d.summary_panel.is_visible());
                assert!(d.next.height() >= 56);
                assert!(
                    d.window.width() <= 810,
                    "narrow layout width {}",
                    d.window.width()
                );
                assert!(
                    d.window.height() <= 400,
                    "compact height {}",
                    d.window.height()
                );
                capture(&d, &path.join("narrow.png"));
                d.act(Action::Back);
                d.hidden = false;
                d.page = 999;
                d.render();
                assert!(d.page < 5);
                // Exercise the same unavailable-output path without asking the compositor to fullscreen.
                d.output.set_selected(0);
                d.requested_output = Some("NONEXISTENT-TEST".into());
                d.refresh_outputs(true);
                d.toggle_fullscreen();
                assert!(!d.window.is_fullscreen());
                assert!(!d.display_warning.is_empty());
                d.page = 0;
                d.render();
            }
            12 => {
                assert_eq!(d.slots, 2);
                assert!(
                    d.window.height() <= 400,
                    "compact overview height {}",
                    d.window.height()
                );
                assert_eq!(d.cards.iter().filter(|c| c.button.is_visible()).count(), 2);
                capture(&d, &path.join("narrow-overview.png"));
                d.sessions.clear();
                d.render();
                assert_eq!(d.page, 0);
                assert!(d.empty.is_visible());
            }
            _ => {
                println!(
                    "Native UI checks passed: cards, pin/hide/restore, history scroll stability, responsive layout, unavailable display."
                );
                d.window.close();
                return glib::ControlFlow::Break;
            }
        }
        step += 1;
        glib::ControlFlow::Continue
    });
}
