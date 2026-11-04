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
struct Extra;
impl Source for Extra {
    fn candidates(&self, _: &str) -> Vec<Suggestion> {
        [90.0_f64, 80.0].into_iter().map(|score| Suggestion { title: "extra".into(), subtitle: String::new(), url: Some("https://extra.test/".into()), key: None, target: Target::Tab { id: score.to_string(), space_id: None }, score }).collect()
    }
}
#[test]
fn extra_source_is_ranked_deduplicated_and_typed_row_is_placed() {
    let rows = command_bar::rank("extra", &[&Extra]);
    assert_eq!(rows.len(), 2); assert_eq!(rows[0].score, 90.0);
    assert!(matches!(rows[1].target, Target::Search { .. }));
    assert!(matches!(command_bar::rank("extra.test", &[&Extra])[0].target, Target::OpenUrl { .. }));
}
#[test]
fn index_covers_sources_and_excludes_the_current_tab() {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None).unwrap().0;
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("tab-b").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("tab-a").unwrap().title = Some("Unique Alpha".into());
    ws.items.get_mut("tab-b").unwrap().title = Some("Unique Beta".into());
    ws.create_space("one", "Other Work", "space-other").unwrap();
    ws.create_folder("folder-other", "Other folder", "space-other:pinned", 0, &[]).unwrap();
    ws.show_space("one", "space-work").unwrap();
    ws.last_selected.insert("tab-a".into(), 100); ws.last_selected.insert("tab-b".into(), 200);
    let idx = Index::new(&ws, "one", 200);
    assert!(matches!(&idx.query("").rows[0].target, Target::Tab { id, .. } if id == "tab-b"));
    assert!(idx.query("unique alpha").rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")));
    assert!(idx.query("settings").rows.iter().any(|s| matches!(&s.target, Target::Command { id } if id == "settings") && s.key.is_some()));
    assert!(idx.query("switch to").rows.iter().any(|s| matches!(&s.target, Target::Space { .. })));
    assert!(idx.query("go to").rows.iter().any(|s| matches!(&s.target, Target::Folder { .. })));
    ws.select_item("one", "tab-a").unwrap();
    let idx = Index::new(&ws, "one", 200);
    assert!(!idx.query("unique alpha").rows.iter().any(|s| matches!(&s.target, Target::Tab { id, .. } if id == "tab-a")));
    let moves = idx.candidates("move tab");
    assert!(moves.iter().any(|s| matches!(&s.target, Target::MoveToSpace { .. })));
    assert!(moves.iter().any(|s| matches!(&s.target, Target::MoveToFolder { .. })));
    ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Archived;
    let idx = Index::new(&ws, "one", 200);
    assert!(idx.query("unique beta").rows.iter().any(|s| matches!(&s.target, Target::Archive { id } if id == "tab-b")));
}

fn fixture() -> ararat_core::model::Workspace {
    arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None).unwrap().0
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
fn archive_limit_and_discount() {
    let mut ws = fixture();
    let template = ws.items["tab-a"].clone();
    for n in 0..401 {
        let mut item = template.clone();
        item.id = format!("arch-{n:03}");
        item.title = Some("Archive probe".into());
        item.lifecycle = Lifecycle::Archived;
        item.lifecycle_changed_at = n;
        ws.items.insert(item.id.clone(), item);
    }
    let rows: Vec<_> = Index::new(&ws, "one", 1000).candidates("archive probe").into_iter().filter(|s| matches!(s.target, Target::Archive { .. })).collect();
    assert_eq!(rows.len(), 400);
    assert!(rows.iter().all(|s| s.score == 80.75));
    assert!(rows.iter().any(|s| matches!(&s.target, Target::Archive { id } if id == "arch-400")));
    assert!(!rows.iter().any(|s| matches!(&s.target, Target::Archive { id } if id == "arch-000")));
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
    let rows = Index::new(&ws, "one", 10).query("").rows;
    assert_eq!(rows.len(), 5);
    let ids: Vec<_> = rows.iter().map(|s| match &s.target { Target::Tab { id, .. } => id.as_str(), _ => panic!("not a tab") }).collect();
    assert_eq!(ids, ["recent-5", "recent-4", "recent-3", "recent-2", "recent-1"]);
}

#[test]
fn typed_placement_and_deduplication() {
    let search = command_bar::rank("query", &[&Extra]);
    assert!(matches!(&search[0].target, Target::Tab { id, .. } if id == "90"));
    assert!(matches!(search[1].target, Target::Search { .. }));
    assert_eq!(search.len(), 2);
    let url = command_bar::rank("example.org", &[&Extra]);
    assert!(matches!(url[0].target, Target::OpenUrl { .. }));
    assert!(matches!(&url[1].target, Target::Tab { id, .. } if id == "90"));
    assert_eq!(url.len(), 2);
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
fn nonempty_results_are_limited_to_five() {
    struct Many;
    impl Source for Many {
        fn candidates(&self, _: &str) -> Vec<Suggestion> {
            (0..8).map(|i| Suggestion { title: i.to_string(), subtitle: String::new(), url: None, key: None, target: Target::Command { id: i.to_string() }, score: i as f64 }).collect()
        }
    }
    let rows = command_bar::rank("query", &[&Many]);
    assert_eq!(rows.len(), 5);
    assert!(matches!(&rows[0].target, Target::Command { id } if id == "7"));
    assert!(matches!(&rows[1].target, Target::Search { .. }));
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
        assert!(idx.query("unloaded").rows.iter().any(|s| matches!(&s.target, Target::Tab { id: found, .. } if found == id)), "search {id}");
        assert!(idx.query("").rows.iter().any(|s| matches!(&s.target, Target::Tab { id: found, .. } if found == id)), "recent {id}");
    }
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

struct Host;
impl Source for Host {
    fn candidates(&self, query: &str) -> Vec<Suggestion> {
        let row = |title: &str, url: &str, score: f64| Suggestion {
            title: title.into(), subtitle: String::new(), url: Some(url.into()), key: None,
            target: Target::Tab { id: "t".into(), space_id: None }, score,
        };
        if query.starts_with('g') { return vec![row("GitHub", "https://github.com/a", 95.0)]; }
        if query.starts_with('w') { return vec![row("Hub", "https://www.github.com/a", 100.0)]; }
        if query.starts_with('l') { return vec![row("Low", "https://lowhost.test/", 80.0)]; }
        vec![]
    }
}

// A host-less row first (about: and kin) must not end the completion search; Cra skips it
// (SuggestionEngine.swift:463).
struct HostlessFirst;
impl Source for HostlessFirst {
    fn candidates(&self, _: &str) -> Vec<Suggestion> {
        vec![
            Suggestion { title: "Blank".into(), subtitle: String::new(), url: Some("about:blank".into()), key: None, target: Target::Tab { id: "t".into(), space_id: None }, score: 100.0 },
            Suggestion { title: "Netflix".into(), subtitle: String::new(), url: Some("https://www.netflix.com/".into()), key: None, target: Target::Tab { id: "t".into(), space_id: None }, score: 95.0 },
        ]
    }
}

#[test]
fn inline_completion_is_the_top_rows_host() {
    let completion = |query: &str| command_bar::rank_with_completion(query, &[&Host]).inline_completion;
    assert_eq!(completion("git").as_deref(), Some("github.com"));
    assert_eq!(completion("githu").as_deref(), Some("github.com"));
    // A www host completes as its bare host, and as the full host when the query keeps www.
    assert_eq!(completion("gith").as_deref(), Some("github.com"));
    assert_eq!(completion("www.git").as_deref(), Some("www.github.com"));
    let rows = command_bar::rank_with_completion("git", &[&Host]).rows;
    assert_eq!(rows.len(), 2);
    assert!(matches!(&rows[0].target, Target::Tab { id, .. } if id == "t"));
    // Guards: no completion below a 90 score, for one character, with a space, or a URL with a path.
    assert_eq!(completion("low"), None);
    assert_eq!(completion("g"), None);
    assert_eq!(completion("gi t"), None);
    assert_eq!(completion("github.com/a"), None);
    assert_eq!(completion("git.h"), None);
    // A host-less row first does not end the search, and the query compares lowercased
    // (Cra S:463 lowercases the query).
    let mixed = |query: &str| command_bar::rank_with_completion(query, &[&HostlessFirst]).inline_completion;
    assert_eq!(mixed("ne"), Some("netflix.com".into()));
    assert_eq!(mixed("Ne"), Some("netflix.com".into()));
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
