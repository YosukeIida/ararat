// Persisting and importing Air Traffic Control rules (unit 29 part A).

use std::collections::HashSet;
use std::path::PathBuf;

use ararat_core::import::{ImportError, LinkRoutingReport, arc_link_routing};
use ararat_core::model::{Id, Kind, Op, Profile, Record, Workspace};
use ararat_core::routing::{Destination, MatchStyle, Rule, Routing, SpaceTarget, UrlCondition};
use ararat_core::storage::Store;
use rusqlite::Connection;

const FIXTURE: &str = include_str!("fixtures/link-routing-synthetic.json");

// The space ids a sidebar import carries: rules may only route to spaces the workspace has.
fn known_spaces() -> HashSet<Id> {
    ["space-work", "space-home"].into_iter().map(String::from).collect()
}

// The same known ids as a route() argument (round 2): the import checked the fixture's
// destinations against exactly these and the order is beside the point, the membership is
// what route() checks.
fn known_ids() -> Vec<Id> {
    known_spaces().into_iter().collect()
}

// The space ids a workspace has now: route() checks a destination's id against these, and a
// destination naming any other one is answered as the most recent space (unit 29b, round 2).
fn space_ids(workspace: &Workspace) -> Vec<Id> {
    workspace.spaces.iter().map(|space| space.id.clone()).collect()
}

fn contains(text: &str) -> UrlCondition {
    UrlCondition { style: MatchStyle::Contains, text: text.into() }
}

fn equals(text: &str) -> UrlCondition {
    UrlCondition { style: MatchStyle::Equals, text: text.into() }
}

fn rule(id: &str, conditions: Vec<UrlCondition>, destination: Destination) -> Rule {
    Rule { id: id.into(), conditions, destination }
}

fn space(id: &str) -> Destination {
    Destination::Space(SpaceTarget::Space(id.into()))
}

fn most_recent() -> Destination {
    Destination::Space(SpaceTarget::MostRecent)
}

// The spaces a rule's Space(id) destination must name (unit 29b): created with the core's own
// create_space, so the ids are real ones the edits accept.
fn with_spaces(workspace: &mut Workspace, ids: &[&str]) {
    for (index, id) in ids.iter().enumerate() {
        workspace.create_space("one", &format!("Space {index}"), id).unwrap();
    }
}

fn little_window() -> Destination {
    Destination::LittleWindow(Profile::Default)
}

fn imported() -> (Routing, LinkRoutingReport) {
    arc_link_routing(FIXTURE, Profile::Default, &known_spaces()).unwrap()
}

fn import_json(json: &str) -> (Routing, LinkRoutingReport) {
    arc_link_routing(json, Profile::Default, &known_spaces()).unwrap()
}

fn fresh_db(name: &str) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("{name}.sqlite"));
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    path
}

// Every stored routing record must equal its last journaled body: the journal is the sync log
// (architecture 8.3), so both sources must agree after every flush.
fn assert_journal_record_agree(path: &PathBuf) {
    let conn = Connection::open(path).unwrap();
    let mut stmt = conn.prepare(
        "SELECT kind, id, body FROM records WHERE kind = 'routing_rule' OR kind = 'routing_default'").unwrap();
    let rows: Vec<(String, String, String)> = stmt.query_map([], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
    }).unwrap().map(|row| row.unwrap()).collect();
    assert!(!rows.is_empty(), "no routing record is stored");
    for (kind, id, body) in rows {
        let journaled: Option<String> = conn.query_row(
            "SELECT body FROM journal WHERE kind = ?1 AND id = ?2 ORDER BY seq DESC LIMIT 1", [&kind, &id],
            |r| r.get(0)).optional().unwrap();
        assert_eq!(Some(body), journaled, "{kind}/{id}");
    }
}

use rusqlite::OptionalExtension;

#[test]
fn add_edit_delete_reorder_and_default_apply_in_order() {
    let mut workspace = Workspace::default();
    with_spaces(&mut workspace, &["space-work", "space-home"]);
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], space("space-work"))).unwrap();
    workspace.add_rule(rule("docs", vec![contains("docs.example.com")], space("space-home"))).unwrap();
    // The first match wins, so the order decides where a URL takes.
    assert_eq!(workspace.routing().route("https://meet.google.com/abc", &space_ids(&workspace)), space("space-work"));

    workspace.edit_rule(rule("docs", vec![contains("docs.example.com")], little_window())).unwrap();
    workspace.move_rule("docs", 0).unwrap();
    assert_eq!(workspace.routing().rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["docs", "meet"]);
    assert_eq!(workspace.routing().route("https://docs.example.com/x", &space_ids(&workspace)), little_window());

    workspace.delete_rule("meet").unwrap();
    assert_eq!(workspace.routing().rules.len(), 1);
    workspace.set_default_destination(most_recent()).unwrap();
    assert_eq!(workspace.routing().route("https://other.example.org", &space_ids(&workspace)), most_recent());
}

#[test]
fn edits_refuse_duplicate_unknown_and_out_of_range() {
    let mut workspace = Workspace::default();
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], little_window())).unwrap();
    assert_eq!(
        workspace.add_rule(rule("meet", vec![contains("meet.google.com")], little_window())).unwrap_err().0,
        "rule meet already exists");
    assert_eq!(
        workspace.edit_rule(rule("other", vec![], little_window())).unwrap_err().0,
        "unknown rule other");
    assert_eq!(
        workspace.delete_rule("other").unwrap_err().0,
        "unknown rule other");
    assert_eq!(
        workspace.move_rule("meet", 1).unwrap_err().0,
        "rule index out of range");
    assert_eq!(
        workspace.move_rule("other", 0).unwrap_err().0,
        "unknown rule other");
    assert_eq!(workspace.add_rule(rule("  ", vec![], little_window())).unwrap_err().0, "rule id is empty");
    // Nothing was written while refusing.
    assert_eq!(workspace.routing().rules.len(), 1);
}

#[test]
fn a_move_that_changes_nothing_writes_nothing() {
    let mut workspace = Workspace::default();
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], little_window())).unwrap();
    workspace.add_rule(rule("docs", vec![contains("docs.example.com")], little_window())).unwrap();
    assert!(workspace.move_rule("meet", 0).unwrap().is_empty());
    // The last position is allowed and equals the current one.
    assert!(workspace.move_rule("docs", 1).unwrap().is_empty());
    assert_eq!(workspace.routing().rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["meet", "docs"]);
}

#[test]
fn edits_journal_one_record_each() {
    let path = fresh_db("routing-journal");
    let mut workspace = Workspace::default();
    with_spaces(&mut workspace, &["space-work"]);
    let (store, _) = Store::open(&path).unwrap();
    let ops = workspace.add_rule(rule("meet", vec![contains("meet.google.com")], space("space-work"))).unwrap();
    assert_eq!(ops.len(), 1);
    assert!(matches!(&ops[0], Op::Put(Record::RoutingRule { .. })));
    store.write(ops);
    let default_ops = workspace.set_default_destination(most_recent()).unwrap();
    assert_eq!(default_ops.len(), 1);
    assert!(matches!(&default_ops[0], Op::Put(Record::RoutingDefault { .. })));
    store.write(default_ops);
    store.flush().unwrap();
    let conn = Connection::open(&path).unwrap();
    let rules: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind = 'routing_rule'", [], |r| r.get(0)).unwrap();
    let defaults: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind = 'routing_default'", [], |r| r.get(0)).unwrap();
    assert_eq!((rules, defaults), (1, 1));
    assert_journal_record_agree(&path);
}

#[test]
fn reopen_and_journal_replay_give_the_same_routing() {
    let path = fresh_db("routing-replay");
    let mut workspace = Workspace::default();
    with_spaces(&mut workspace, &["space-work", "space-home"]);
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], space("space-work"))).unwrap();
    workspace.add_rule(rule("docs", vec![contains("docs.example.com")], little_window())).unwrap();
    workspace.edit_rule(rule("docs", vec![equals("https://docs.example.com/")], space("space-home"))).unwrap();
    workspace.move_rule("docs", 0).unwrap();
    workspace.delete_rule("meet").unwrap();
    workspace.set_default_destination(most_recent()).unwrap();
    {
        let (store, _) = Store::open(&path).unwrap();
        store.write(workspace.to_ops());
        store.flush().unwrap();
    }
    let (_, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened.routing(), workspace.routing());

    // A journal replay is what a sync device does with uploaded blobs: apply each journaled
    // record in sequence order onto an empty workspace.
    let conn = Connection::open(&path).unwrap();
    let mut stmt = conn.prepare("SELECT kind, id, body FROM journal ORDER BY seq").unwrap();
    let rows = stmt.query_map([], |r| {
        Ok((r.get::<_, String>(0).unwrap(), r.get::<_, String>(1).unwrap(), r.get::<_, Option<String>>(2).unwrap()))
    }).unwrap().map(|row| row.unwrap()).collect::<Vec<_>>();
    let mut replay = Workspace::default();
    for (kind, id, body) in rows {
        let kind = Kind::parse(&kind).unwrap();
        let op = match body {
            Some(body) => Op::Put(Record::parse(kind, &id, &body).unwrap()),
            None => Op::Delete(kind, id),
        };
        replay.apply(&op);
    }
    assert_eq!(replay.routing(), workspace.routing());
}

#[test]
fn contains_maps_to_match_style_contains() {
    let (routing, _) = imported();
    // Arc's seeded route is a "contains" rule to the space of most-recent tabs (Cra
    // LinkRouting.swift googleMeet); Meet.Google.Com keeps its case until matching.
    assert_eq!(routing.rules[0], rule("meet", vec![contains("Meet.Google.Com")], most_recent()));
    assert_eq!(routing.route("https://www.meet.google.com/abc", &known_ids()), most_recent());
}

#[test]
fn matches_maps_to_match_style_equals() {
    let (routing, _) = imported();
    assert_eq!(routing.rules[1], rule("github-prs", vec![equals("https://github.com/pulls/")], space("space-work")));
    assert_eq!(routing.route("https://github.com/pulls?q=1", &known_ids()), space("space-work"));
    assert_eq!(routing.route("https://github.com/pulls/assigned", &known_ids()), Routing::default().default);
}

#[test]
fn a_space_id_destination_maps_to_space_target_space() {
    // Fixture assumption: the space-with-id variant inside `destination` is `space: {_0: "<id>"}`,
    // the same externally-tagged `_0` slot the owner's file carries for most-recent.
    let (routing, _) = imported();
    assert_eq!(routing.rules[1].destination, space("space-work"));
    assert_eq!(routing.rules[3].destination, space("space-home"));
}

#[test]
fn little_arc_maps_to_little_window_with_the_import_profile() {
    // Fixture assumption: `littleArc` wraps a profile destination `{"mostRecent": {}}`; the
    // Little window record carries the profile the import belongs to (this fixture: Default).
    let (routing, _) = imported();
    assert_eq!(routing.rules[2], rule("docs-little", vec![contains("docs.example.com")], little_window()));
    assert_eq!(routing.route("https://docs.example.com/spec", &known_ids()), little_window());
    // The import's profile is an argument of the import, not file data.
    let json = r#"{"version":1,"rules":[{"id":"meet","sourceComponents":[{"id":"m","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"meet.google.com"}}}],"destination":{"littleArc":{"_0":{"mostRecent":{}}}}}],"defaultDestination":{"littleArc":{"_0":{"mostRecent":{}}}}}"#;
    let (routing, _) = arc_link_routing(json, Profile::Named("Profile 1".into()), &known_spaces()).unwrap();
    assert_eq!(routing.rules[0].destination, Destination::LittleWindow(Profile::Named("Profile 1".into())));
    assert_eq!(routing.default, Destination::LittleWindow(Profile::Named("Profile 1".into())));
}

#[test]
fn a_profile_destination_skips_the_rule_and_is_counted() {
    let (routing, report) = imported();
    assert!(!routing.rules.iter().any(|r| r.id == "profile-destination"));
    assert_eq!(report.skipped_profile_destinations, 1);
    assert_eq!(report.imported_rules, 4);
}

#[test]
fn an_unknown_style_skips_the_rule_and_is_counted() {
    let (routing, report) = imported();
    assert!(!routing.rules.iter().any(|r| r.id == "unknown-style"));
    assert_eq!(report.skipped_unknown_styles, 1);
}

#[test]
fn an_unknown_destination_skips_the_rule_and_is_counted() {
    let (routing, report) = imported();
    assert!(!routing.rules.iter().any(|r| r.id == "unknown-destination"));
    assert_eq!(report.skipped_unknown_destinations, 1);
}

#[test]
fn a_rule_without_an_id_is_counted_malformed() {
    let (routing, report) = imported();
    assert!(!routing.rules.iter().any(|r| r.id == ""));
    assert_eq!(report.malformed_rules, 1);
    assert_eq!(report.imported_rules, 4);
}

#[test]
fn multi_component_rules_import_all_conditions_in_file_order() {
    let (routing, _) = imported();
    assert_eq!(routing.rules[3], rule("double-condition", vec![contains("a.example"), equals("https://b.example/")], space("space-home")));
}

#[test]
fn imported_rules_keep_the_file_order() {
    let (routing, _) = imported();
    assert_eq!(routing.rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["meet", "github-prs", "docs-little", "double-condition"]);
}

#[test]
fn the_default_destination_maps_like_a_rule_destination() {
    let (routing, _) = imported();
    assert_eq!(routing.default, little_window());
}

#[test]
fn a_missing_or_unknown_version_is_refused() {
    let json = r#"{"rules":[]}"#;
    assert_eq!(arc_link_routing(json, Profile::Default, &known_spaces()).map(|_| ()).unwrap_err().0, "StorableLinkRouting has no version");
    let json = r#"{"version":2,"rules":[],"defaultDestination":{"littleArc":{"_0":{"mostRecent":{}}}}}"#;
    assert_eq!(
        arc_link_routing(json, Profile::Default, &known_spaces()).map(|_| ()).unwrap_err().0,
        "StorableLinkRouting version 2 is not supported");
    // A string version is not the integer Arc writes, so it is not version 1 either.
    let json = r#"{"version":"1","rules":[]}"#;
    assert_eq!(
        arc_link_routing(json, Profile::Default, &known_spaces()).map(|_| ()).unwrap_err().0,
        "StorableLinkRouting version \"1\" is not supported");
}

#[test]
fn no_rules_and_no_default_destination_keep_ours() {
    // A version-1 file with the rules list absent, as a partial write could leave it.
    let json = r#"{"version":1}"#;
    let (routing, report) = arc_link_routing(json, Profile::Default, &known_spaces()).unwrap();
    assert_eq!(routing, Routing::default());
    assert_eq!(report, LinkRoutingReport::default());
}

#[test]
fn a_broken_rules_list_is_refused() {
    let json = r#"{"version":1,"rules":"all"}"#;
    assert_eq!(
        arc_link_routing(json, Profile::Default, &known_spaces()).map(|_| ()).unwrap_err().0,
        "rules is not an array");
}

// The import reuses the sidebar's error type, so one message crosses the same FFI surface.
#[test]
fn import_errors_are_import_errors() {
    let json = "{not json";
    assert!(matches!(arc_link_routing(json, Profile::Default, &known_spaces()), Err(ImportError(_))));
}

// Review 1a should 1: two devices editing different rules before they sync. Records merge per
// rule, so both changes land and both devices end with the same rule order (ties by id).
#[test]
fn two_devices_cross_applying_ops_keeps_both_changes() {
    let base = |ws: &mut Workspace| {
        with_spaces(ws, &["space-work", "space-home"]);
        ws.add_rule(rule("g1", vec![contains("github.com")], space("space-work"))).unwrap();
        ws.add_rule(rule("g2", vec![contains("docs.example.com")], most_recent())).unwrap();
        ws.add_rule(rule("g3", vec![contains("meet.google.com")], little_window())).unwrap();
    };
    let mut a = Workspace::default();
    base(&mut a);
    let mut b = Workspace::default();
    base(&mut b);
    // Device A edits a rule, adds one, moves another to the front, changes the default.
    let ops_a = [
        a.edit_rule(rule("g1", vec![contains("github.com")], most_recent())).unwrap(),
        a.add_rule(rule("zoom", vec![contains("zoom.example")], space("space-home"))).unwrap(),
        a.move_rule("g3", 0).unwrap(),
        a.set_default_destination(space("space-work")).unwrap(),
    ].concat();
    // Device B adds a rule computed from the same base A's add started from (so the two adds
    // tie on their order key), deletes one, moves one.
    let ops_b = [
        b.add_rule(rule("meet", vec![contains("meet.google.com")], space("space-work"))).unwrap(),
        b.delete_rule("g2").unwrap(),
        b.move_rule("g1", 0).unwrap(),
    ].concat();
    for op in &ops_b { a.apply(op); }
    for op in &ops_a { b.apply(op); }
    // Same records, so the same derived order; both devices saw every change.
    assert_eq!(a.routing(), b.routing());
    let settled = a.routing();
    let ids: Vec<&str> = settled.rules.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids, ["g3", "g1", "meet", "zoom"]);
    assert_eq!(a.routing().default, space("space-work"));
    assert_eq!(a.routing().rules.iter().find(|r| r.id == "g1").unwrap().destination, most_recent());
}

// Review 1a nit 3: an edit that changes nothing writes no record.
#[test]
fn edits_that_change_nothing_write_nothing() {
    let mut ws = Workspace::default();
    ws.add_rule(rule("meet", vec![contains("meet.google.com")], little_window())).unwrap();
    // The same rule content again: no change, so no record.
    assert!(ws.edit_rule(rule("meet", vec![contains("meet.google.com")], little_window())).unwrap().is_empty());
    // The destination it already has: no record either.
    assert!(ws.set_default_destination(little_window()).unwrap().is_empty());
    assert_eq!(ws.routing().rules.len(), 1);
}

// Review 2a nit: a default set back to the built-in one is a reset, not a Put of the value —
// the tombstone removes the stored record and re-plays the built-in default on any device.
#[test]
fn a_default_reset_writes_a_tombstone() {
    let path = fresh_db("routing-tombstone");
    let mut workspace = Workspace::default();
    let changed = workspace.set_default_destination(most_recent()).unwrap();
    assert!(matches!(&changed[0], Op::Put(Record::RoutingDefault { .. })));
    // The built-in destination is reached by deleting the stored one (unit 28's resets delete
    // their override), not by writing a Put that holds the built-in value.
    let reset = workspace.set_default_destination(Destination::default()).unwrap();
    assert_eq!(reset.len(), 1);
    assert!(matches!(&reset[0], Op::Delete(Kind::RoutingDefault, id) if id == "workspace"));
    {
        let (store, _) = Store::open(&path).unwrap();
        store.write(changed);
        store.write(reset);
        store.flush().unwrap();
    }
    let conn = Connection::open(&path).unwrap();
    let journal: Option<Option<String>> = conn
        .query_row(
            "SELECT body FROM journal WHERE kind = 'routing_default' ORDER BY seq DESC LIMIT 1",
            [], |r| r.get(0))
        .optional().unwrap();
    // The settled journal state is the tombstone, so a replay reads the built-in default.
    assert!(journal.is_some_and(|body| body.is_none()));
    let stored: i64 = conn.query_row("SELECT count(*) FROM records WHERE kind = 'routing_default'", [], |r| r.get(0)).unwrap();
    assert_eq!(stored, 0);
    // The reset also left the workspace's own routing at the built-in default.
    let (_, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened.routing().default, Destination::default());
    // The delete did not touch other routing state: no rule records existed here either way.
    assert!(reopened.routing_rules.is_empty());
}

// Review 1a should 2: a workspace whose routing equals the built-in default emits no routing
// records at all, so a full write cannot reset saved rules (unit 28's defaults rule holds).
#[test]
fn to_ops_carries_only_changed_routing() {
    assert!(Workspace::default().to_ops().is_empty());
    let mut ws = Workspace::default();
    ws.add_rule(rule("meet", vec![contains("meet.google.com")], little_window())).unwrap();
    assert_eq!(ws.to_ops().len(), 1);
    ws.set_default_destination(most_recent()).unwrap();
    assert_eq!(ws.to_ops().len(), 2);
    // Back on the built-in default, the default record is unnecessary again.
    ws.set_default_destination(little_window()).unwrap();
    assert_eq!(ws.to_ops().len(), 1);
}

// Review 1a nit 1: a repeated rule id would make edit/delete ambiguous; the first wins and
// the rest are counted like other unreadable entries.
#[test]
fn a_repeated_rule_id_keeps_the_first_and_counts_the_rest() {
    let json = r#"{"version":1,"rules":[
      {"id":"meet","sourceComponents":[{"id":"m","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"meet.google.com"}}}],"destination":{"space":{"_0":{"mostRecent":{}}}}},
      {"id":"meet","sourceComponents":[{"id":"m2","componentType":{"urlMatch":{"_0":{"matches":{}},"_1":"https://other.example/"}}}],"destination":{"space":{"_0":"space-work"}}}]}"#;
    let (routing, report) = import_json(json);
    assert_eq!(routing.rules.len(), 1);
    // The first entry is the one that survived an add-like conflict and stays importable.
    assert_eq!(routing.rules[0].conditions[0].text, "meet.google.com");
    assert_eq!(report.imported_rules, 1);
    assert_eq!(report.malformed_rules, 1);
}

// Review 1a nit 2: only a space id the sidebar carries is imported; anything else is skipped
// and counted. The rule destination and the file's default check the same way.
#[test]
fn an_unknown_space_id_is_skipped_and_counted() {
    let json = r#"{"version":1,
      "rules":[{"id":"meet","sourceComponents":[{"id":"m","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"meet.google.com"}}}],"destination":{"space":{"_0":"not-a-space"}}}],
      "defaultDestination":{"space":{"_0":"not-a-space"}}}"#;
    let (routing, report) = import_json(json);
    assert!(routing.rules.is_empty());
    assert_eq!(report.skipped_unknown_destinations, 2);
    assert_eq!(routing.default, Routing::default().default);
}

// Review 1a nit 2: the id string must match a known space id exactly, as Cra checks its
// string against the sidebar's space ids; a near-match (case differences, a title) is not an
// id and is skipped and counted.
#[test]
fn a_space_destination_id_must_match_a_known_space_exactly() {
    let json = r#"{"version":1,
      "rules":[{"id":"case","sourceComponents":[{"id":"c","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"case.example.com"}}}],"destination":{"space":{"_0":"Space-Work"}}}]}"#;
    let (routing, report) = import_json(json);
    assert!(routing.rules.is_empty());
    assert_eq!(report.skipped_unknown_destinations, 1);
}

// An order key two rules share reads in id order, so a tie keeps every device's list equal:
// two devices adding a rule in the same spot both computed key_between over the same base.
#[test]
fn tied_order_keys_read_in_rule_id_order() {
    let mut ws = Workspace::default();
    for (id, order) in [("zoom", "w"), ("meet", "w")] {
        ws.apply(&Op::Put(Record::RoutingRule {
            order: order.into(),
            rule: rule(id, vec![contains(&format!("{id}.example"))], little_window()),
        }));
    }
    assert_eq!(ws.routing().rules.iter().map(|r| r.id.clone()).collect::<Vec<_>>(), ["meet", "zoom"]);
}

// A move whose neighbours tie is the seam unit 22 re-keys for items: without re-keying the new
// key would have to fall between two equal keys.
#[test]
fn a_move_onto_a_tied_run_rekeys_it() {
    let mut ws = Workspace::default();
    for (id, order) in [("early", "a"), ("other", "w"), ("zoom", "w"), ("first", "z")] {
        ws.apply(&Op::Put(Record::RoutingRule {
            order: order.into(),
            rule: rule(id, vec![contains(&format!("{id}.example"))], little_window()),
        }));
    }
    // Moving "first" into the seam between the tied "other" and "zoom" re-keys the run instead
    // of asking for a key inside one.
    ws.move_rule("first", 2).unwrap();
    assert_eq!(ws.routing().rules.iter().map(|r| r.id.clone()).collect::<Vec<_>>(), ["early", "other", "first", "zoom"]);
}

// Part B: the routing imports beside the sidebar. The sibling file list mirrors Arc's:
// StorableSidebar + StorableWindows + StorableKeyBindings + StorableLinkRouting.
const SIDEBAR: &str = include_str!("fixtures/arc-sidebar-synthetic.json");
const WINDOWS: &str = include_str!("fixtures/StorableWindows.json");
const KEY_BINDINGS: &str = r#"{"version":1,"userOverrides":[]}"#;

// The whole sibling set imports in one call: the sidebar's spaces gate the destinations and
// its profile is the one Little-window destinations belong to.
#[test]
fn a_fixture_set_of_all_three_siblings_imports_the_routing() {
    let (workspace, report) = ararat_core::import::arc_sidebar(SIDEBAR, Some(WINDOWS), Some(KEY_BINDINGS), Some(FIXTURE)).unwrap();
    assert!(!report.missing_link_routing);
    assert_eq!(report.link_routing_error, None);
    assert_eq!(report.imported_rules, 4);
    assert_eq!(report.skipped_profile_destinations, 1);
    assert_eq!(report.skipped_unknown_destinations, 1);
    assert_eq!(report.skipped_unknown_styles, 1);
    assert_eq!(report.malformed_rules, 1);
    let routing = workspace.routing();
    assert_eq!(routing.rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["meet", "github-prs", "docs-little", "double-condition"]);
    assert_eq!(routing.route("https://www.meet.google.com/abc", &space_ids(&workspace)), most_recent());
    assert_eq!(routing.route("https://github.com/pulls", &space_ids(&workspace)), space("space-work"));
    // The file's default (littleArc → The Little window with the import's profile) is the
    // built-in one on this fixture, so the derived default emits no extra record.
    assert_eq!(routing.default, Destination::default());
    assert!(!workspace.to_ops().iter().any(|op| matches!(op, Op::Put(Record::RoutingDefault { .. }))));
}

// A routing sibling that is absent, unreadable or full of replacement characters (the harness
// decodes files lossily) still imports the sidebar; only the report notes it.
#[test]
fn missing_malformed_and_non_utf8_routing_files_still_import_the_sidebar() {
    let (workspace, report) = ararat_core::import::arc_sidebar(SIDEBAR, None, None, None).unwrap();
    assert!(report.missing_link_routing);
    assert_eq!(report.link_routing_error, None);
    assert_eq!(workspace.spaces.len(), 2);

    let json = "{\"version\":1,\"rules\":}";
    let (workspace, report) = ararat_core::import::arc_sidebar(SIDEBAR, None, None, Some(json)).unwrap();
    assert!(!report.missing_link_routing);
    assert!(report.link_routing_error.is_some());
    assert_eq!(workspace.spaces.len(), 2);
    assert!(workspace.routing().rules.is_empty());

    let lossy = String::from_utf8_lossy(&[b'{', b'"', 0xff, b'"', b'}']).into_owned();
    let (workspace, report) = ararat_core::import::arc_sidebar(SIDEBAR, None, None, Some(&lossy)).unwrap();
    assert!(!report.missing_link_routing);
    assert!(report.link_routing_error.is_some());
    assert_eq!(workspace.spaces.len(), 2);
}

// Unit 29b, owner's ruling: a rule (or the default) may only name a space the workspace has —
// the import checks the sidebar's ids the same way. Each op refuses with an EditError and the
// state stays unchanged.
#[test]
fn edits_refuse_a_space_destination_the_workspace_does_not_have() {
    let mut workspace = Workspace::default();
    workspace.create_space("one", "Work", "space-work").unwrap();
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], little_window())).unwrap();
    let before = workspace.clone();
    // add_rule refuses the unknown space and writes nothing.
    assert_eq!(
        workspace.add_rule(rule("gone", vec![contains("gone.example")], space("space-gone"))).unwrap_err().0,
        "unknown space space-gone");
    assert_eq!(workspace, before);
    // edit_rule refuses it on an existing rule too.
    assert_eq!(
        workspace.edit_rule(rule("meet", vec![contains("meet.google.com")], space("space-gone"))).unwrap_err().0,
        "unknown space space-gone");
    assert_eq!(workspace, before);
    // set_default_destination refuses it as well.
    assert_eq!(
        workspace.set_default_destination(space("space-gone")).unwrap_err().0,
        "unknown space space-gone");
    assert_eq!(workspace, before);
}

// Unit 29b, round 2, ruling 1: an edit is allowed to keep the rule's current destination
// even when that space was deleted (a text or style change writes, so the user can still
// fix the rule); a destination the edit changes to on top is refused like an unknown space,
// as round 1 pinned.
#[test]
fn edit_rule_refuses_only_a_changed_destination_that_names_a_missing_space() {
    let mut workspace = Workspace::default();
    workspace.create_space("one", "Work", "space-work").unwrap();
    workspace.create_space("one", "Home", "space-home").unwrap();
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], space("space-work"))).unwrap();
    workspace.delete_space("space-work").unwrap();
    let before = workspace.clone();
    // A destination change on top of the carried one is refused (round 1's ruling).
    assert_eq!(
        workspace.edit_rule(rule("meet", vec![contains("changed.example")], space("space-gone"))).unwrap_err().0,
        "unknown space space-gone");
    assert_eq!(workspace, before);
    // An edit keeping the rule's current destination writes: text or style only.
    workspace.edit_rule(rule("meet", vec![contains("changed.example")], space("space-work"))).unwrap();
    assert_eq!(
        workspace.routing().rules.iter().find(|r| r.id == "meet").unwrap().conditions,
        vec![contains("changed.example")]);
    assert_eq!(
        workspace.routing().rules.iter().find(|r| r.id == "meet").unwrap().destination,
        space("space-work"));
    workspace.edit_rule(rule("meet", vec![equals("https://changed.example/")], space("space-work"))).unwrap();
    assert_eq!(
        workspace.routing().rules.iter().find(|r| r.id == "meet").unwrap().conditions,
        vec![equals("https://changed.example/")]);
}

// MostRecent and the Little window carry no space id, so they pass even on a workspace with
// no spaces at all (the refusal only reaches Space(id) destinations).
#[test]
fn most_recent_and_little_window_destinations_pass_without_spaces() {
    let mut workspace = Workspace::default();
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], most_recent())).unwrap();
    workspace.add_rule(rule("docs", vec![contains("docs.example.com")], little_window())).unwrap();
    workspace.edit_rule(rule("docs", vec![equals("https://docs.example.com/")], most_recent())).unwrap();
    workspace.set_default_destination(most_recent()).unwrap();
    assert_eq!(workspace.routing().rules.len(), 2);
    assert_eq!(workspace.routing().default, most_recent());
}

// Unit 29b, round 2, ruling 2 + the still-standing refusal of round 1: a space deleted after
// a rule was written leaves the rule's destination naming it. route() still matches the rule
// and its link goes to the most recent space instead of the stale id (ours, Arc's behaviour
// unobserved); the same applies to the default destination naming a deleted space. The edits
// only refuse a destination the edit adds: add_rule, an edit_rule destination change, and
// set_default_destination refuse the deleted space like an unknown one.
#[test]
fn a_deleted_space_still_refuses_new_destinations_and_route_answers_most_recent() {
    let mut workspace = Workspace::default();
    workspace.create_space("one", "Work", "space-work").unwrap();
    workspace.create_space("one", "Home", "space-home").unwrap();
    workspace.create_space("one", "Again", "space-again").unwrap();
    workspace.set_default_destination(space("space-home")).unwrap();
    workspace.add_rule(rule("meet", vec![contains("meet.google.com")], space("space-work"))).unwrap();
    workspace.delete_space("space-work").unwrap();
    let spaces = space_ids(&workspace);
    let before = workspace.clone();
    // The rule and the default keep their destinations: the routing snapshot is not
    // rewritten, the pane shows the deleted space from it (round 2, ruling 3).
    assert_eq!(
        workspace.routing().rules.iter().find(|r| r.id == "meet").unwrap().destination,
        space("space-work"));
    assert_eq!(workspace.routing().default, space("space-home"));
    // route() still matches the rule, and the link goes to the most recent space.
    assert_eq!(workspace.routing().rule_for("https://meet.google.com/abc").unwrap().id, "meet");
    assert_eq!(workspace.routing().route("https://meet.google.com/abc", &spaces), most_recent());
    // Refusal of round 1 stands: add_rule, an edit that changes the destination, and
    // set_default_destination refuse a deleted space like an unknown one, state unchanged.
    assert_eq!(
        workspace.add_rule(rule("again", vec![contains("again.example")], space("space-work"))).unwrap_err().0,
        "unknown space space-work");
    assert_eq!(
        workspace.edit_rule(rule("meet", vec![contains("changed.example")], space("space-gone"))).unwrap_err().0,
        "unknown space space-gone");
    assert_eq!(
        workspace.set_default_destination(space("space-work")).unwrap_err().0,
        "unknown space space-work");
    assert_eq!(workspace, before);
    // The same rewrite for the default: the space it names is deleted, a URL no rule matches
    // goes to the most recent space instead of the stale default.
    workspace.delete_space("space-home").unwrap();
    assert_eq!(workspace.routing().default, space("space-home"));
    assert_eq!(workspace.routing().route("https://other.example.org", &space_ids(&workspace)), most_recent());
}

