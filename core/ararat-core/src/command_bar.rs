use std::collections::HashSet;
use crate::key_bindings::KeyCombination;
use crate::model::{ItemKind, Lifecycle, Workspace};

pub const SEARCH_URL: &str = "https://www.google.com/search?q=";

pub fn search_url(query: &str) -> String {
    let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
    format!("{SEARCH_URL}{encoded}")
}

#[derive(Debug, Clone, PartialEq)]
pub enum Target {
    Tab { id: String, space_id: Option<String> },
    Archive { id: String },
    OpenUrl { url: String },
    Search { url: String },
    Command { id: String },
    Space { id: String },
    Folder { id: String, space_id: String },
    MoveToSpace { id: String },
    MoveToFolder { id: String, space_id: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Suggestion {
    pub title: String,
    pub subtitle: String,
    pub url: Option<String>,
    pub key: Option<KeyCombination>,
    pub target: Target,
    pub score: f64,
}

pub trait Source {
    fn candidates(&self, query: &str) -> Vec<Suggestion>;
}

#[derive(Clone)]
struct Entry {
    suggestion: Suggestion,
    custom_title: bool,
    selected: Option<u64>,
    archived: bool,
}

pub struct Index {
    entries: Vec<(Entry, Option<SearchKey>)>,
    now: u64,
}

// Scoring and the per-open index are adapted from Cra's MIT-licensed SuggestionEngine.swift.
impl Index {
    pub fn new(ws: &Workspace, window: &str, now: u64) -> Self {
        let mut entries = Vec::new();
        let current = ws.selected(window);
        let shown_space = ws.shown_space(window);
        let current_profile = current.and_then(|id| ws.item_profile(id));
        let current_root = current.and_then(|id| ws.list_for(id)).map(|(root, _)| root);
        let current_space = ws.spaces.iter().find(|space| current_root.is_some_and(|root| root == space.pinned || root == space.today))
            .or_else(|| ws.spaces.iter().find(|space| Some(space.id.as_str()) == shown_space && current_profile == Some(&space.profile)));
        let current_folder = current.and_then(|id| ws.items.get(id)).and_then(|item| item.membership.parent.clone())
            .filter(|parent| ws.items.get(parent).is_some_and(|i| matches!(i.kind, ItemKind::Folder)));
        // Space moves skip the tab's own space; folder moves keep it (moving into a pinned folder
        // of the same space is the common case), dropping only the folder the tab is already in.
        let can_move_to = |space: &crate::model::Space| current_profile == Some(&space.profile) && current_space.is_some_and(|current| current.id != space.id);
        let can_move_folder_to = |space: &crate::model::Space| current_profile == Some(&space.profile);
        let current_split = current.and_then(|id| ws.outermost_split(id));
        let excluded = |item: &crate::model::Item| Some(item.id.as_str()) == current ||
            current_split.as_ref().is_some_and(|split| ws.outermost_split(&item.id).as_ref() == Some(split));
        let mut seen = HashSet::new();
        for space in &ws.spaces {
            for (root, pinned) in [(&space.pinned, true), (&space.today, false)] {
                let mut stack = ws.children(root).into_iter().rev().collect::<Vec<_>>();
                while let Some(item) = stack.pop() {
                    if !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) { continue; }
                    stack.extend(ws.children(&item.id).into_iter().rev());
                    match &item.kind {
                        ItemKind::Tab { url, .. } if !excluded(item) => {
                            seen.insert(item.id.clone());
                            entries.push(Entry { suggestion: Suggestion { title: item.display_title().into(), subtitle: if pinned { format!("{} · Pinned", space.title) } else { space.title.clone() }, url: Some(url.clone()), key: None, target: Target::Tab { id: item.id.clone(), space_id: Some(space.id.clone()) }, score: 0.0 }, custom_title: item.title.is_some(), selected: ws.last_selected.get(&item.id).copied(), archived: false });
                        }
                        ItemKind::Folder => {
                            for (title, target) in [(format!("Go to {}", item.display_title()), Target::Folder { id: item.id.clone(), space_id: space.id.clone() }), (format!("Move Tab to {}", item.display_title()), Target::MoveToFolder { id: item.id.clone(), space_id: space.id.clone() })] {
                                let skip = match &target { Target::MoveToFolder { id, .. } => !can_move_folder_to(space) || Some(id.as_str()) == current_folder.as_deref(), _ => false };
                                if skip { continue; }
                                entries.push(Entry { suggestion: Suggestion { title, subtitle: "Folder".into(), url: None, key: None, target, score: 0.0 }, custom_title: false, selected: None, archived: false });
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        let mut favorites: Vec<_> = ws.favorites.values().collect();
        favorites.sort();
        for root in favorites {
            let mut stack = ws.children(root).into_iter().rev().collect::<Vec<_>>();
            while let Some(item) = stack.pop() {
                if !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) { continue; }
                stack.extend(ws.children(&item.id).into_iter().rev());
                if let ItemKind::Tab { url, .. } = &item.kind {
                    if !excluded(item) && seen.insert(item.id.clone()) {
                        entries.push(Entry { suggestion: Suggestion { title: item.display_title().into(), subtitle: "Favorite".into(), url: Some(url.clone()), key: None, target: Target::Tab { id: item.id.clone(), space_id: None }, score: 0.0 }, custom_title: item.title.is_some(), selected: ws.last_selected.get(&item.id).copied(), archived: false });
                    }
                }
            }
        }
        for item in ws.archive().into_iter().take(400) {
            if let ItemKind::Tab { url, .. } = &item.kind {
                entries.push(Entry { suggestion: Suggestion { title: item.display_title().into(), subtitle: "Archived".into(), url: Some(url.clone()), key: None, target: Target::Archive { id: item.id.clone() }, score: 0.0 }, custom_title: false, selected: None, archived: true });
            }
        }
        for binding in ws.key_bindings() {
            entries.push(Entry { suggestion: Suggestion { title: binding.command.title, subtitle: "Command".into(), url: None, key: binding.key, target: Target::Command { id: binding.command.id }, score: 0.0 }, custom_title: false, selected: None, archived: false });
        }
        for space in &ws.spaces {
            for (title, target) in [(format!("Switch to {}", space.title), Target::Space { id: space.id.clone() }), (format!("Move Tab to {}", space.title), Target::MoveToSpace { id: space.id.clone() })] {
                if matches!(target, Target::Space { .. }) && Some(space.id.as_str()) == shown_space { continue; }
                if matches!(target, Target::MoveToSpace { .. }) && !can_move_to(space) { continue; }
                entries.push(Entry { suggestion: Suggestion { title, subtitle: "Space".into(), url: None, key: None, target, score: 0.0 }, custom_title: false, selected: None, archived: false });
            }
        }
        let entries = entries.into_iter().map(|entry| {
            let key = entry.suggestion.url.as_ref().map(|url| {
                let mut key = SearchKey::new(&entry.suggestion.title, url);
                let id = match &entry.suggestion.target { Target::Tab { id, .. } | Target::Archive { id } => Some(id), _ => None };
                key.saved_title = id.and_then(|id| ws.items.get(id)).and_then(|item| match &item.kind {
                    ItemKind::Tab { saved_title, .. } => saved_title.as_ref().map(|s| s.to_lowercase()), _ => None,
                });
                key
            });
            (entry, key)
        }).collect();
        Self { entries, now }
    }

    pub fn query(&self, query: &str) -> CommandBarResult { rank_with_completion(query, &[self]) }
}

impl Source for Index {
    fn candidates(&self, query: &str) -> Vec<Suggestion> {
        let q = query.to_lowercase();
        let mut entries = self.entries.clone();
        if q.is_empty() {
            entries.retain(|(e, _)| matches!(e.suggestion.target, Target::Tab { .. }));
            entries.sort_by(|(a, _), (b, _)| b.selected.cmp(&a.selected));
            return entries.into_iter().map(|(e, _)| e.suggestion).collect();
        }
        entries.into_iter().filter_map(|(mut e, key)| {
            let title = e.suggestion.title.to_lowercase();
            let score = if let Some(key) = key {
                let mut score = score_key(&q, &key);
                if e.archived { score *= 0.85; }
                else if e.custom_title && title.starts_with(&q) { score += 40.0; }
                if score < 30.0 { return None; }
                if !e.archived {
                    let age = e.selected.map(|at| self.now.saturating_sub(at));
                    score += match age { Some(a) if a < 600_000 => 30.0, Some(a) if a < 3_600_000 => 22.0, Some(a) if a < 86_400_000 => 14.0, Some(a) if a < 604_800_000 => 7.0, _ => 0.0 };
                }
                score
            } else {
                if q.chars().count() < 2 { return None; }
                let trigger = match e.suggestion.target {
                    Target::Space { .. } => title.strip_prefix("switch to "),
                    Target::Folder { .. } => title.strip_prefix("go to "),
                    Target::MoveToSpace { .. } | Target::MoveToFolder { .. } => title.strip_prefix("move tab to "),
                    _ => None,
                };
                if title.starts_with(&q) { 80.0 } else if title.split_whitespace().any(|w| w.starts_with(&q)) { 68.0 } else if trigger.is_some_and(|t| t.starts_with(&q)) { 70.0 } else if title.contains(&q) { 50.0 } else { return None; }
            };
            e.suggestion.score = score;
            Some(e.suggestion)
        }).collect()
    }
}

pub fn text_score(query: &str, title: &str, url: &str) -> f64 {
    score_key(&query.to_lowercase(), &SearchKey::new(title, url))
}

#[derive(Clone)]
struct SearchKey { title: String, saved_title: Option<String>, human: String, host: String }

impl SearchKey {
    fn new(title: &str, url: &str) -> Self {
        let url = url.to_lowercase();
        let human = url.trim_start_matches("https://").trim_start_matches("http://").trim_start_matches("www.").to_owned();
        let host = url::Url::parse(&url).ok().and_then(|u| u.host_str().map(str::to_owned)).unwrap_or_default();
        Self { title: title.to_lowercase(), saved_title: None, human, host }
    }
}

fn score_key(q: &str, key: &SearchKey) -> f64 {
    let score = score_title(q, &key.title, &key.human, &key.host);
    key.saved_title.as_ref().map_or(score, |title| score.max(score_title(q, title, &key.human, &key.host)))
}

fn score_title(q: &str, title: &str, human: &str, host: &str) -> f64 {
    if q.is_empty() { return 0.0; }
    let tokens: Vec<_> = q.split_whitespace().collect();
    if tokens.len() > 1 {
        if title.starts_with(&q) { return 95.0; }
        let hits = tokens.iter().filter(|t| title.contains(**t) || human.contains(**t)).count();
        return if hits == tokens.len() { 75.0 } else { 30.0 * hits as f64 / tokens.len() as f64 };
    }
    let mut score: f64 = if title.starts_with(&q) { 100.0 } else if title.split(|c: char| !c.is_alphanumeric()).any(|w| w.starts_with(&q)) { 85.0 } else if title.contains(&q) { 65.0 } else { fuzzy(&q, &title) };
    let bare = host.trim_start_matches("www.");
    if bare.starts_with(&q) || host.starts_with(&q) { score = score.max(95.0); }
    else if bare.contains(&q) { score = score.max(70.0); }
    else if human.contains(&q) { score = score.max(55.0); }
    score
}

fn fuzzy(q: &str, title: &str) -> f64 {
    let count = q.chars().count();
    if count < 3 { return 0.0; }
    let mut chars = title.chars();
    let mut gaps = 0;
    for c in q.chars() {
        let mut gap = false;
        loop { match chars.next() { Some(x) if x == c => break, Some(_) => gap = true, None => return 0.0 } }
        if gap { gaps += 1; }
    }
    25.0 + 25.0 * (1.0 - gaps as f64 / count as f64).max(0.0)
}

pub fn looks_like_url(input: &str) -> bool {
    let s = input.trim();
    if s.is_empty() || s.chars().any(char::is_whitespace) { return false; }
    if s.starts_with("about:") || s.starts_with("file:") { return true; }
    if let Some((scheme, _)) = s.split_once("://") {
        let mut chars = scheme.chars();
        return chars.next().is_some_and(|c| c.is_ascii_alphabetic()) && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    }
    let host_port = s.split('/').next().unwrap_or("");
    let (host, port) = host_port.split_once(':').map_or((host_port, None), |(h,p)| (h, Some(p)));
    if port.is_some_and(|p| p.is_empty() || !p.chars().all(|c| c.is_ascii_digit())) { return false; }
    if host == "localhost" || host.parse::<std::net::Ipv4Addr>().is_ok() { return true; }
    host.contains('.') && host.split('.').all(|part| !part.is_empty() && part.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_'))
}

pub fn rank(query: &str, sources: &[&dyn Source]) -> Vec<Suggestion> {
    rank_with_completion(query, sources).rows
}

#[derive(Debug, Clone, PartialEq)]
pub struct CommandBarResult {
    pub rows: Vec<Suggestion>,
    pub inline_completion: Option<String>,
}

pub fn rank_with_completion(query: &str, sources: &[&dyn Source]) -> CommandBarResult {
    let query = query.trim();
    let mut results: Vec<_> = sources.iter().flat_map(|s| s.candidates(query)).collect();
    if query.is_empty() { results.truncate(5); return CommandBarResult { rows: results, inline_completion: None }; }
    results.sort_by(|a, b| b.score.total_cmp(&a.score));
    let mut seen = HashSet::new();
    results.retain(|s| s.url.as_ref().is_none_or(|u| seen.insert(u.clone())));
    let inline_completion = inline_completion(query, &results);
    let url_like = looks_like_url(query);
    let target = if url_like {
        let host = query.split('/').next().unwrap_or("").split(':').next().unwrap_or("");
        let url = if query.contains("://") || query.starts_with("about:") || query.starts_with("file:") { query.to_string() } else if host == "localhost" || host.parse::<std::net::Ipv4Addr>().is_ok() { format!("http://{query}") } else { format!("https://{query}") };
        Target::OpenUrl { url }
    } else {
        Target::Search { url: search_url(query) }
    };
    let typed = Suggestion { title: query.into(), subtitle: if url_like { "Open URL" } else { "Search" }.into(), url: None, key: None, target, score: 0.0 };
    results.insert(if url_like || results.is_empty() { 0 } else { 1 }, typed);
    results.truncate(5);
    CommandBarResult { rows: results, inline_completion }
}

// Cra's MIT SuggestionEngine.swift:461-470: the bare host of a high-scoring candidate that the
// query prefixes, so Tab and → can accept it in the field. The query compares lowercased, and a
// host-less row (about:, file: and kin) is skipped, not the end of the search (Cra S:463).
fn inline_completion(query: &str, rows: &[Suggestion]) -> Option<String> {
    let query = query.to_lowercase();
    if query.contains(' ') || query.chars().count() < 2 { return None; }
    if looks_like_url(&query) && query.contains('/') { return None; }
    for row in rows {
        let Some(url) = &row.url else { continue };
        if row.score < 90.0 { continue; }
        let Ok(parsed) = url::Url::parse(url) else { continue };
        let Some(host) = parsed.host_str() else { continue };
        let host = host.to_lowercase();
        let bare = host.strip_prefix("www.").unwrap_or(&host);
        if bare.starts_with(&query) && bare != query { return Some(bare.into()); }
        if host.starts_with(&query) && host != query { return Some(host.into()); }
    }
    None
}
