use ararat_core::{command_bar::{self, Index, Source, Suggestion, Target}, import::arc_sidebar, model::{ItemKind, Lifecycle, Op, Record}};

macro_rules! score_test {
    ($name:ident, $query:expr, $title:expr, $url:expr, $score:expr) => {
        #[test] fn $name() { assert!((command_bar::text_score($query, $title, $url) - $score).abs() < 0.001); }
    };
}
score_test!(title_prefix, "alp", "Alpha", "https://other.test/", 100.0);
score_test!(word_prefix, "alp", "The Alpha", "https://other.test/", 85.0);
score_test!(host_prefix, "alp", "Other", "https://alpha.test/", 95.0);
score_test!(host_contains, "pha", "Other", "https://alpha.test/", 70.0);
score_test!(title_substring, "pha", "Alpha", "https://other.test/", 65.0);
score_test!(url_contains, "path", "Other", "https://other.test/path", 55.0);
score_test!(fuzzy_subsequence, "abc", "aXbXc", "https://other.test/", 25.0 + 25.0 / 3.0);
score_test!(multiple_words, "alpha beta", "Other alpha", "https://other.test/beta", 75.0);
score_test!(multiple_words_prefix, "alpha beta", "Alpha Beta", "https://other.test/", 95.0);
#[test]
fn url_detection_and_typed_rows() {
    for (input, expected) in [("https://example.com", true), ("localhost:3000/a", true), ("127.0.0.1/a", true), ("about:blank", true), ("file:///tmp/x", true), ("example.com:443/a", true), ("hello world", false), ("hello", false), ("example.com:abc", false), ("1bad://host", false)] { assert_eq!(command_bar::looks_like_url(input), expected, "{input}"); }
    assert!(matches!(&command_bar::rank("localhost:3000", &[])[0].target, Target::OpenUrl { url } if url == "http://localhost:3000"));
    assert!(matches!(&command_bar::rank("hello world", &[])[0].target, Target::Search { url } if url.ends_with("hello+world")));
}
#[test]
fn search_url_encodes_url_like_and_unicode_input() {
    assert_eq!(command_bar::search_url("example.com & 日本"), "https://www.google.com/search?q=example.com+%26+%E6%97%A5%E6%9C%AC");
}
struct Extra;
impl Source for Extra {
    fn candidates(&self, _: &str) -> Vec<Suggestion> {
        [90.0_f64, 80.0].into_iter().map(|score| Suggestion { title: "extra".into(), subtitle: String::new(), url: Some("https://extra.test/".into()), key: None, target: Target::Tab { id: score.to_string(), space_id: None }, score }).collect()
    }
}
#[test]
fn extra_source_is_ranked_deduplicated_and_typed_row_comes_first() {
    let rows = command_bar::rank("extra", &[&Extra]);
    // The typed row is always first (D1); the source's rows follow, deduplicated by URL.
    assert_eq!(rows.len(), 2);
    assert!(matches!(rows[0].target, Target::Search { .. }));
    assert_eq!(rows[1].score, 90.0);
    assert!(matches!(command_bar::rank("extra.test", &[&Extra])[0].target, Target::OpenUrl { .. }));
}
#[test]
fn index_covers_sources_and_excludes_the_current_tab() {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("tab-b").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("tab-a").unwrap().title = Some("Unique Alpha".into());
    ws.items.get_mut("tab-b").unwrap().title = Some("Unique Beta".into());
    ws.create_space("one", "Other Work", "space-other").unwrap();
    ws.create_folder("folder-other", "Other folder", "space-other:pinned", 0, &[]).unwrap();
    ws.show_space("one", "space-work").unwrap();
    ws.last_selected.insert("tab-a".into(), 100); ws.last_selected.insert("tab-b".into(), 200);
    let idx = Index::new(&ws, "one", 200);
    assert!(matches!(&idx.query("", &[]).rows[0].target, Target::Tab { id, .. } if id == "tab-b"));
    assert!(idx.query("unique alpha", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")));
    assert!(idx.query("settings", &[]).rows.iter().any(|s| matches!(&s.target, Target::Command { id } if id == "settings") && s.key.is_some()));
    assert!(idx.query("switch to", &[]).rows.iter().any(|s| matches!(&s.target, Target::Space { .. })));
    assert!(idx.query("go to", &[]).rows.iter().any(|s| matches!(&s.target, Target::Folder { .. })));
    ws.select_item("one", "tab-a").unwrap();
    let idx = Index::new(&ws, "one", 200);
    assert!(!idx.query("unique alpha", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")));
    let moves = idx.candidates("move tab");
    assert!(moves.iter().any(|s| matches!(&s.target, Target::MoveToSpace { .. })));
    assert!(moves.iter().any(|s| matches!(&s.target, Target::MoveToFolder { .. })));
    ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Archived;
    let idx = Index::new(&ws, "one", 200);
    assert!(!idx.query("unique beta", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-b")));
}

fn fixture() -> ararat_core::model::Workspace {
    arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0
}

#[test]
fn every_default_command_is_reachable_by_its_full_title() {
    let workspace = fixture();
    let index = Index::new(&workspace, "one", 0);
    for command in ararat_core::key_bindings::commands() {
        let rows = index.query(&command.title, &[]).rows;
        assert!(rows.iter().take(5).any(|row| matches!(&row.target, Target::Command { id } if id == &command.id)), "{}", command.id);
    }
}

#[test]
fn recency_boundaries() {
    let mut ws = fixture();
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("tab-a").unwrap().title = Some("Recency probe".into());
    let now = 1_000_000_000;
    for (age, boost) in [(0, 30.0), (599_999, 30.0), (600_000, 22.0), (3_599_999, 22.0), (3_600_000, 14.0), (86_399_999, 14.0), (86_400_000, 7.0), (604_799_999, 7.0), (604_800_000, 0.0)] {
        ws.last_selected.insert("tab-a".into(), now - age);
        let row = Index::new(&ws, "one", now).candidates("recency").into_iter().find(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")).unwrap();
        assert_eq!(row.score, 140.0 + boost, "age {age}");
    }
    ws.last_selected.remove("tab-a");
    let row = Index::new(&ws, "one", now).candidates("recency").into_iter().find(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")).unwrap();
    assert_eq!(row.score, 140.0);
}

#[test]
fn archive_rows_are_gone_and_the_visible_rows_keep_their_scores() {
    let mut ws = fixture();
    let template = ws.items["tab-a"].clone();
    for n in 0..3 {
        let mut item = template.clone();
        item.id = format!("arch-{n:03}");
        item.title = Some("Archive probe".into());
        item.lifecycle = Lifecycle::Archived;
        item.lifecycle_changed_at = n;
        ws.items.insert(item.id.clone(), item);
    }
    // D2: the bar draws no archive rows at all — the Library owns the archive.
    let rows = Index::new(&ws, "one", 1000).query("archive probe", &[]).rows;
    assert!(!rows.iter().any(|s| s.url.as_deref() == Some("https://a.example.com")));
    assert!(matches!(&rows[0].target, Target::Search { .. }));
}

#[test]
fn typed_url_and_search_cases() {
    for (input, expected) in [
        ("custom+scheme://host/path", Some("custom+scheme://host/path")),
        ("localhost", Some("http://localhost")), ("localhost:1234/path", Some("http://localhost:1234/path")),
        ("about:blank", Some("about:blank")), ("file:///tmp/test", Some("file:///tmp/test")), ("file:relative", Some("file:relative")),
        ("127.0.0.1:80/path", Some("http://127.0.0.1:80/path")),
        ("example.org", Some("https://example.org")), ("example.org:443/path", Some("https://example.org:443/path")),
        ("not a url.example", None), ("https://example.org/a b", None), ("word", None), ("example.org:bad/path", None), ("bad scheme://host", None),
    ] {
        let rows = command_bar::rank(input, &[]);
        match (&rows[0].target, expected) {
            (Target::OpenUrl { url }, Some(expected)) => assert_eq!(url, expected, "{input}"),
            (Target::Search { url }, None) => assert!(url.starts_with(command_bar::SEARCH_URL), "{input}"),
            _ => panic!("wrong target for {input}"),
        }
    }
}

#[test]
fn excludes_current_tab_and_selected_split_members() {
    let mut ws = fixture();
    ws.select_item("one", "tab-spec").unwrap();
    let rows = Index::new(&ws, "one", 0).candidates("");
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-spec")));
    assert!(rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")));
    ws.select_item("one", "split-1").unwrap();
    let rows = Index::new(&ws, "one", 0).candidates("");
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a" || id == "tab-b")));
    assert!(rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-spec")));
}

#[test]
fn empty_query_orders_recent_tabs_and_limits_to_five() {
    let mut ws = fixture();
    let template = ws.items["tab-a"].clone();
    for n in 0..6 {
        let mut item = template.clone();
        item.id = format!("recent-{n}");
        item.membership.parent = Some("today-work".into());
        item.membership.order = n.to_string();
        ws.last_selected.insert(item.id.clone(), n + 1);
        ws.items.insert(item.id.clone(), item);
    }
    let rows = Index::new(&ws, "one", 10).query("", &[]).rows;
    assert_eq!(rows.len(), 5);
    let ids: Vec<_> = rows.iter().map(|s| match &s.target { Target::Tab { id, .. } => id.as_str(), _ => panic!("not a tab") }).collect();
    assert_eq!(ids, ["recent-5", "recent-4", "recent-3", "recent-2", "recent-1"]);
}

#[test]
fn empty_query_is_the_shown_space_s_own_recents_without_the_current_tab_or_favourites() {
    let mut ws = fixture();
    // A tab of the other space (space-home) and a favourite (tab-mail) are outside the list.
    let mut home = ws.items["tab-a"].clone();
    home.id = "tab-home".into();
    home.membership.parent = Some("today-home".into());
    home.title = Some("Home probe".into());
    ws.items.insert(home.id.clone(), home);
    ws.last_selected.insert("tab-home".into(), 900);
    ws.last_selected.insert("tab-mail".into(), 800);
    ws.last_selected.insert("tab-spec".into(), 700);
    ws.show_space("one", "space-work").unwrap();
    let rows = Index::new(&ws, "one", 1000).query("", &[]).rows;
    let ids: Vec<_> = rows.iter().map(|s| match &s.target { Target::Tab { id, .. } => id.as_str(), _ => panic!("not a tab") }).collect();
    assert_eq!(ids, ["tab-spec", "tab-a", "tab-b"]);
    // The favourite and the other space stay reachable once something is typed.
    assert!(Index::new(&ws, "one", 1000).query("mail", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-mail")));
    assert!(Index::new(&ws, "one", 1000).query("home probe", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-home")));
    // The shown space's own list shrinks when it has fewer tabs than five (no filling in).
    ws.show_space("one", "space-home").unwrap();
    assert_eq!(Index::new(&ws, "one", 1000).query("", &[]).rows.iter().filter(|s| matches!(s.target, Target::Tab { .. })).count(), 1);
}

#[test]
fn typed_row_is_always_first_over_a_matching_row() {
    let search = command_bar::rank("query", &[&Extra]);
    assert!(matches!(&search[0].target, Target::Search { .. }), "the typed row leads");
    assert!(matches!(&search[1].target, Target::Tab { id, .. } if id == "90"));
    assert_eq!(search.len(), 2);
    let url = command_bar::rank("example.org", &[&Extra]);
    assert!(matches!(url[0].target, Target::OpenUrl { .. }));
    assert!(matches!(&url[1].target, Target::Tab { id, .. } if id == "90"));
    assert_eq!(url.len(), 2);
    // D1: a tab that matches better than the typed text still comes second.
    let workspace = fixture();
    let index = Index::new(&workspace, "one", 0);
    let rows = index.query("Spec (renamed)", &[]).rows;
    assert!(matches!(&rows[0].target, Target::Search { .. }));
    assert!(matches!(&rows[1].target, Target::Tab { id, .. } if id == "tab-spec"));
}

#[test]
fn command_scores_and_destination_trigger() {
    let mut ws = fixture();
    ws.spaces.iter_mut().find(|s| s.id == "space-work").unwrap().title = "Work Place".into();
    ws.show_space("one", "space-home").unwrap();
    let idx = Index::new(&ws, "one", 0);
    for (query, id, expected) in [("sett", "settings", 80.0), ("tab", "close_tab", 68.0), ("lose", "close_tab", 50.0)] {
        let rows = idx.candidates(query);
        let row = rows.iter().find(|s| matches!(&s.target, Target::Command { id: found } if found == id)).unwrap();
        assert_eq!(row.score, expected);
    }
    let rows = idx.candidates("work pl");
    assert_eq!(rows.iter().find(|s| matches!(&s.target, Target::Space { id } if id == "space-work")).unwrap().score, 70.0);
    assert!(idx.candidates("s").iter().all(|s| !matches!(s.target, Target::Command { .. })));
}

#[test]
fn custom_title_boost_and_weak_match_cutoff() {
    let mut ws = fixture();
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("tab-a").unwrap().title = Some("Probe".into());
    let idx = Index::new(&ws, "one", 0);
    let rows = idx.candidates("probe");
    assert_eq!(rows.iter().find(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")).unwrap().score, 140.0);
    ws.items.get_mut("tab-a").unwrap().title = Some("xa yb zc".into());
    ws.last_selected.insert("tab-a".into(), 0);
    let idx = Index::new(&ws, "one", 0);
    assert!(!idx.candidates("abc").iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")));
}

#[test]
fn equal_scores_keep_source_order() {
    struct Ordered;
    impl Source for Ordered {
        fn candidates(&self, _: &str) -> Vec<Suggestion> {
            ["first", "second"].into_iter().map(|id| Suggestion { title: id.into(), subtitle: String::new(), url: Some(format!("https://{id}.test")), key: None, target: Target::Command { id: id.into() }, score: 80.0 }).collect()
        }
    }
    let rows = command_bar::rank("query", &[&Ordered]);
    assert_eq!(rows.iter().filter_map(|s| match &s.target { Target::Command { id } => Some(id.as_str()), _ => None }).collect::<Vec<_>>(), ["first", "second"]);
}

#[test]
fn pinned_and_saved_titles_are_searchable() {
    let mut ws = fixture();
    let item = ws.items.get_mut("tab-spec").unwrap();
    item.title = Some("Custom name".into());
    if let ararat_core::model::ItemKind::Tab { saved_title, .. } = &mut item.kind { *saved_title = Some("Saved title".into()); }
    let idx = Index::new(&ws, "one", 0);
    let rows = idx.candidates("saved title");
    let row = rows.iter().find(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-spec")).unwrap();
    assert!(row.subtitle.contains("Pinned"));
    assert_eq!(row.score, 95.0);
}

#[test]
fn nonempty_results_are_limited_to_five_and_the_typed_row_counts() {
    struct Many;
    impl Source for Many {
        fn candidates(&self, _: &str) -> Vec<Suggestion> {
            (0..8).map(|i| Suggestion { title: i.to_string(), subtitle: String::new(), url: None, key: None, target: Target::Command { id: i.to_string() }, score: i as f64 }).collect()
        }
    }
    let rows = command_bar::rank("query", &[&Many]);
    assert_eq!(rows.len(), 5);
    // The typed row takes one of the five (D1), so four candidates follow it.
    assert!(matches!(&rows[0].target, Target::Search { .. }));
    assert!(matches!(&rows[1].target, Target::Command { id } if id == "7"));
    assert!(matches!(&rows[4].target, Target::Command { id } if id == "4"));
}

#[test]
fn unloaded_tabs_in_pinned_today_and_favorites_are_searchable_and_recent() {
    let mut ws = fixture();
    for (id, title, parent, at) in [("tab-a", "Unloaded pinned", "pin-work", 3), ("tab-b", "Unloaded today", "today-work", 2), ("tab-mail", "Unloaded favorite", "fav-default", 1)] {
        let item = ws.items.get_mut(id).unwrap();
        item.membership.parent = Some(parent.into());
        item.lifecycle = Lifecycle::Unloaded;
        item.title = Some(title.into());
        ws.last_selected.insert(id.into(), at);
    }
    let idx = Index::new(&ws, "one", 3);
    for id in ["tab-a", "tab-b", "tab-mail"] {
        assert!(idx.query("unloaded", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id: found, .. } if found == id)), "search {id}");
    }
    // Unloaded in-space tabs stay in the empty list; a favourite does not (D4).
    for id in ["tab-a", "tab-b"] {
        assert!(idx.query("", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id: found, .. } if found == id)), "recent {id}");
    }
    assert!(!idx.query("", &[]).rows.iter().any(|s| matches!(&s.target, Target::Tab { id: found, .. } if found == "tab-mail")));
}

#[test]
fn move_destinations_match_current_profile_and_exclude_current_space() {
    let mut ws = fixture();
    ws.show_space("one", "space-work").unwrap();
    ws.create_space("one", "Other Work", "space-other").unwrap();
    ws.create_folder("folder-other", "Other folder", "space-other:pinned", 0, &[]).unwrap();
    ws.create_folder("folder-home", "Home folder", "pin-home", 0, &[]).unwrap();
    ws.show_space("one", "space-work").unwrap();
    ws.select_item("one", "tab-a").unwrap();
    let idx = Index::new(&ws, "one", 0);
    let rows = idx.candidates("move tab");
    assert!(rows.iter().any(|s| matches!(&s.target, Target::MoveToSpace { id } if id == "space-other")));
    // Folders of the tab's own space are offered, other same-profile spaces too.
    assert!(rows.iter().any(|s| matches!(&s.target, Target::MoveToFolder { id, .. } if id == "folder-docs")));
    assert!(rows.iter().any(|s| matches!(&s.target, Target::MoveToFolder { id, .. } if id == "folder-other")));
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::MoveToSpace { id } if id == "space-work" || id == "space-home")));
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::MoveToFolder { id, .. } if id == "folder-home")));
}

#[test]
fn move_folder_destinations_skip_the_tab_s_own_folder() {
    let mut ws = fixture();
    ws.create_space("one", "Other Work", "space-other").unwrap();
    ws.create_folder("folder-other", "Other folder", "space-other:pinned", 0, &[]).unwrap();
    ws.select_item("one", "tab-spec").unwrap();
    let idx = Index::new(&ws, "one", 0);
    let rows = idx.candidates("move tab");
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::MoveToFolder { id, .. } if id == "folder-docs")));
    assert!(rows.iter().any(|s| matches!(&s.target, Target::MoveToFolder { id, .. } if id == "folder-other")));
}

#[test]
fn switch_space_excludes_shown_space() {
    let mut ws = fixture();
    ws.show_space("one", "space-work").unwrap();
    let rows = Index::new(&ws, "one", 0).candidates("switch to");
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::Space { id } if id == "space-work")));
    assert!(rows.iter().any(|s| matches!(&s.target, Target::Space { id } if id == "space-home")));
    ws.show_space("one", "space-home").unwrap();
    let rows = Index::new(&ws, "one", 0).candidates("switch to");
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::Space { id } if id == "space-home")));
    assert!(rows.iter().any(|s| matches!(&s.target, Target::Space { id } if id == "space-work")));
}

#[test]
fn favorite_subtitle_is_favorite() {
    let ws = fixture();
    let rows = Index::new(&ws, "one", 0).candidates("mail");
    assert_eq!(rows.iter().find(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-mail")).unwrap().subtitle, "Favorite");
}

#[test]
fn move_destinations_use_selected_tab_profile_even_if_shown_space_changes() {
    let mut ws = fixture();
    ws.show_space("one", "space-work").unwrap();
    ws.create_space("one", "Other Work", "space-other").unwrap();
    ws.show_space("one", "space-work").unwrap();
    ws.select_item("one", "tab-a").unwrap();
    ws.show_space("one", "space-home").unwrap();
    let rows = Index::new(&ws, "one", 0).candidates("move tab");
    assert!(rows.iter().any(|s| matches!(&s.target, Target::MoveToSpace { id } if id == "space-other")));
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::MoveToSpace { id } if id == "space-home" || id == "space-work")));
}

#[test]
fn favorite_move_destinations_use_favorites_profile_and_shown_space() {
    let mut ws = fixture();
    ws.show_space("one", "space-work").unwrap();
    ws.create_space("one", "Other Work", "space-other").unwrap();
    ws.show_space("one", "space-work").unwrap();
    ws.select_item("one", "tab-mail").unwrap();
    let rows = Index::new(&ws, "one", 0).candidates("move tab");
    assert!(rows.iter().any(|s| matches!(&s.target, Target::MoveToSpace { id } if id == "space-other")));
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::MoveToSpace { id } if id == "space-work" || id == "space-home")));
}

#[test]
fn create_tab_adds_a_selected_open_tab_to_the_shown_space_today() {
    let mut ws = fixture();
    ws.show_space("one", "space-home").unwrap();
    let ops = ws.create_tab("one", "https://example.org/page").unwrap();
    let created: Vec<_> = ops.iter().filter_map(|op| match op {
        Op::Put(Record::Item(item)) if matches!(item.kind, ItemKind::Tab { .. }) => Some(item.id.clone()), _ => None,
    }).collect();
    assert_eq!(created.len(), 1);
    let id = created[0].as_str();
    assert!(matches!(&ws.items[id].kind, ItemKind::Tab { url, .. } if url == "https://example.org/page"));
    assert!(matches!(ws.items[id].lifecycle, Lifecycle::Open));
    assert_eq!(ws.items[id].membership.parent.as_deref(), Some("today-home"));
    assert_eq!(ws.selected("one"), Some(id));
    assert_eq!(ws.shown_space("one"), Some("space-home"));
    assert!(ws.last_selected.contains_key(id));
    // A workspace with no shown space falls back to the first space.
    let mut ws = fixture();
    let ops = ws.create_tab("one", "https://example.org/").unwrap();
    let created: Vec<_> = ops.iter().filter_map(|op| match op {
        Op::Put(Record::Item(item)) if matches!(item.kind, ItemKind::Tab { .. }) => Some(item.id.clone()), _ => None,
    }).collect();
    assert_eq!(created.len(), 1);
    assert_eq!(ws.items[created[0].as_str()].membership.parent.as_deref(), Some("today-work"));
    assert_eq!(ws.selected("one"), Some(created[0].as_str()));
}

#[test]
fn set_tab_url_updates_an_open_tab_and_refuses_others() {
    let mut ws = fixture();
    ws.set_tab_url("tab-a", "https://new.example.org/page").unwrap();
    assert!(matches!(&ws.items["tab-a"].kind, ItemKind::Tab { url, .. } if url == "https://new.example.org/page"));
    ws.items.get_mut("tab-a").unwrap().lifecycle = Lifecycle::Archived;
    assert!(ws.set_tab_url("tab-a", "https://x.example.org/").is_err());
    assert!(ws.set_tab_url("folder-docs", "https://x.example.org/").is_err());
}

fn history(title: &str, url: &str, last_visit: u64) -> command_bar::HistoryEntry {
    command_bar::HistoryEntry { title: title.into(), url: url.into(), last_visit }
}

#[test]
fn rows_group_as_open_tabs_then_history_then_commands() {
    // D2: a group outranks a score. The history page scores 130 and the command 80, and the tab
    // (40) still leads them both; the command stays last although it beats the tab on score.
    // The command's title holds the query in the middle of a word, so D2's exception (a title
    // that starts with the text) does not apply here.
    struct Fixed;
    impl Source for Fixed {
        fn candidates(&self, _: &str) -> Vec<Suggestion> {
            vec![
                Suggestion { title: "Unprobed command".into(), subtitle: "Command".into(), url: None, key: None, target: Target::Command { id: "c".into() }, score: 80.0 },
                Suggestion { title: "Probe tab".into(), subtitle: "Work".into(), url: Some("https://tab.test/".into()), key: None,
                    target: Target::Tab { id: "t".into(), space_id: Some("space-work".into()) }, score: 40.0 },
            ]
        }
    }
    let entries = [history("Probe history", "https://history.test/", 900_000)];
    let history = command_bar::HistorySource::new(&entries, 1_000_000);
    let rows = command_bar::rank_result("probe", &[&Fixed, &history], false).rows;
    let kinds: Vec<&str> = rows.iter().map(|s| match s.target {
        Target::Search { .. } => "typed",
        Target::Tab { .. } => "tab",
        Target::History { .. } => "history",
        Target::Command { .. } => "command",
        _ => "other",
    }).collect();
    assert_eq!(kinds, ["typed", "tab", "history", "command"]);
    let row = &rows[2];
    assert_eq!(row.subtitle, "History");
    assert_eq!(row.url.as_deref(), Some("https://history.test/"));
    assert_eq!(row.score, 100.0 + 30.0, "the shared recency steps apply to a visit");
}

#[test]
fn an_exact_command_title_follows_the_typed_row_ahead_of_matching_tabs() {
    // D2's exception: five open tabs whose titles start with "Set" outscore Settings… on points
    // (100 + recency each), and Settings… still takes the second row; the tabs follow it.
    let mut ws = fixture();
    let template = ws.items["tab-a"].clone();
    for n in 0..5 {
        let mut item = template.clone();
        item.id = format!("set-tab-{n}");
        item.title = Some(format!("Settings page {n}"));
        if let ItemKind::Tab { url, .. } = &mut item.kind { *url = format!("https://set-{n}.test/"); }
        item.membership.parent = Some("today-work".into());
        item.lifecycle = Lifecycle::Open;
        ws.last_selected.insert(item.id.clone(), 900 + n);
        ws.items.insert(item.id.clone(), item);
    }
    let rows = Index::new(&ws, "one", 1000).query("set", &[]).rows;
    assert_eq!(rows.len(), 5, "the typed row keeps its place inside the five");
    assert!(matches!(&rows[0].target, Target::Search { .. }));
    assert!(matches!(&rows[1].target, Target::Command { id } if id == "settings"), "an exact command title follows the typed row");
    assert!(rows[2..].iter().all(|row| matches!(row.target, Target::Tab { .. })), "the tabs follow the command");
    assert_eq!(rows.iter().filter(|row| matches!(row.target, Target::Command { .. })).count(), 1, "one command is promoted");
    // A multi-word title prefix promotes too ("Close Tab" starts with "close t").
    let rows = Index::new(&ws, "one", 1000).query("close t", &[]).rows;
    assert!(matches!(&rows[1].target, Target::Command { id } if id == "close_tab"));
    // And a word start inside a command's title: "tab" reaches "Close Tab" without matching the
    // title's first word. The table's order breaks the tie with New Tab and Pin Tab.
    let rows = Index::new(&ws, "one", 1000).query("tab", &[]).rows;
    assert!(matches!(&rows[1].target, Target::Command { id } if id == "close_tab"), "the word branch promotes a title's inner word");
}

#[test]
fn only_one_command_is_promoted_so_short_queries_keep_their_tabs() {
    // Review 2: nine Show Space rows (and for "sp" the nine Move to Space rows as well) used to
    // fill tier 0 and crowd every tab out. One command is promoted; the tabs that fit follow it.
    let mut ws = fixture();
    let template = ws.items["tab-a"].clone();
    for (id, title, selected) in [("shop-tab", "Shopping", 900), ("shop-receipts", "Shop receipts", 800), ("shell-docs", "Shell docs", 700),
                                  ("spotify-tab", "Spotify", 600), ("spreadsheet-tab", "Spreadsheet", 500), ("sports-tab", "Sports scores", 400)] {
        let mut item = template.clone();
        item.id = id.into();
        item.title = Some(title.into());
        if let ItemKind::Tab { url, .. } = &mut item.kind { *url = format!("https://{id}.test/"); }
        item.membership.parent = Some("today-work".into());
        item.lifecycle = Lifecycle::Open;
        ws.last_selected.insert(id.into(), selected);
        ws.items.insert(id.into(), item);
    }
    let index = Index::new(&ws, "one", 1000);
    for (query, tabs) in [("sh", 3), ("sp", 3)] {
        let rows = index.query(query, &[]).rows;
        assert_eq!(rows.len(), 5, "{query}: the five rows are full");
        assert!(matches!(&rows[0].target, Target::Search { .. }), "{query}: the typed row leads");
        // Exactly one promoted command: the highest score, then the command table's order. Every
        // Show Space and Move to Space row scores alike, so Show Space 1 leads.
        assert!(matches!(&rows[1].target, Target::Command { id } if id == "show_space_1"), "{query}: one command at row 2");
        assert_eq!(rows.iter().filter(|row| matches!(row.target, Target::Command { .. })).count(), 1, "{query}: no second command");
        assert_eq!(rows[2..].iter().filter(|row| matches!(row.target, Target::Tab { .. })).count(), tabs, "{query}: the tabs show after it");
    }
    // "sho" matches the three Sh tabs (the third by fuzzy title) and they all follow the one
    // command, which is what the old unlimited promotion broke.
    let rows = index.query("sho", &[]).rows;
    assert_eq!(rows.iter().filter(|row| matches!(row.target, Target::Tab { .. })).count(), 3, "sho keeps the matching tabs");
    assert_eq!(rows.iter().filter(|row| matches!(row.target, Target::Command { .. })).count(), 1);
}

#[test]
fn history_rows_score_like_a_tab_and_never_take_the_empty_list() {
    let ws = fixture();
    let index = Index::new(&ws, "one", 1_000_000).private_window(false);
    let entries = [history("Design tokens reference", "https://docs.example.org/design/tokens", 0)];
    // The title prefix scores 100; no visit time means no recency boost.
    let rows = index.query("design tokens", &entries).rows;
    let row = rows.iter().find(|s| matches!(s.target, Target::History { .. })).unwrap();
    assert_eq!(row.score, 95.0, "a two-word prefix scores 95, as a tab's does");
    // A weak match is cut like a weak tab match.
    assert!(!index.query("zz", &[history("Design tokens reference", "https://docs.example.org/design/tokens", 0)]).rows.iter().any(|s| matches!(s.target, Target::History { .. })));
    // Nothing typed: the five recent tabs only, no history rows.
    assert!(!index.query("", &entries).rows.iter().any(|s| matches!(s.target, Target::History { .. })));
}

#[test]
fn a_history_page_of_an_open_tab_is_dropped_in_the_tab_s_favour() {
    // The fixture's pinned tab-spec is https://docs.example.com/spec; history holds the same page.
    let ws = fixture();
    let entries = [history("Spec", "https://docs.example.com/spec", 1_000_000)];
    let rows = Index::new(&ws, "one", 1_000_000).query("spec", &entries).rows;
    // One row for the URL: the open tab's, never both.
    let spec: Vec<_> = rows.iter().filter(|s| s.url.as_deref() == Some("https://docs.example.com/spec")).collect();
    assert_eq!(spec.len(), 1);
    assert!(matches!(spec[0].target, Target::Tab { .. }));
}

#[test]
fn a_private_query_withholds_history_and_says_so() {
    let ws = fixture();
    let entries = [history("Design tokens reference", "https://docs.example.org/design/tokens", 0)];
    let private = Index::new(&ws, "one", 1_000_000).private_window(true);
    let result = private.query("design tokens", &entries);
    assert!(result.private_window);
    assert!(!result.rows.iter().any(|s| matches!(s.target, Target::History { .. })), "no history rows in a private window");
    assert!(result.rows.iter().any(|s| matches!(s.target, Target::Tab { .. } | Target::Search { .. })));
    // The same query in a regular window keeps them.
    assert!(Index::new(&ws, "one", 1_000_000).private_window(false).query("design tokens", &entries).rows.iter().any(|s| matches!(s.target, Target::History { .. })));
    assert!(!command_bar::rank("design tokens", &[]).iter().any(|s| matches!(s.target, Target::History { .. })));
}

#[test]
fn recent_tabs_are_the_shown_space_s_mru_minus_the_current_tab_and_favourites() {
    let mut ws = fixture();
    ws.show_space("one", "space-work").unwrap();
    ws.last_selected.insert("tab-a".into(), 10);
    ws.last_selected.insert("tab-b".into(), 30);
    ws.last_selected.insert("tab-spec".into(), 20);
    ws.last_selected.insert("tab-mail".into(), 40);
    let ids = |rows: Vec<Suggestion>| rows.into_iter().map(|s| match s.target { Target::Tab { id, .. } => id, _ => panic!("not a tab") }).collect::<Vec<_>>();
    assert_eq!(ids(command_bar::recent_tabs(&ws, "one", 5)), ["tab-b", "tab-spec", "tab-a"]);
    // The selected tab leaves the list; a shown split leaves as a whole, and a tab outside it stays.
    ws.select_item("one", "tab-spec").unwrap();
    assert_eq!(ids(command_bar::recent_tabs(&ws, "one", 5)), ["tab-b", "tab-a"]);
    ws.select_item("one", "split-1").unwrap();
    assert_eq!(ids(command_bar::recent_tabs(&ws, "one", 5)), ["tab-spec"]);
    // A favourite is not one of the space's tabs, and the limit is honoured.
    ws.clear_selection("one");
    assert!(!ids(command_bar::recent_tabs(&ws, "one", 5)).contains(&"tab-mail".to_string()));
    assert_eq!(command_bar::recent_tabs(&ws, "one", 2).len(), 2);
    // The empty command-bar list and the switcher share the rule.
    assert_eq!(ids(command_bar::recent_tabs(&ws, "one", 5)), ids(Index::new(&ws, "one", 0).query("", &[]).rows));
}
