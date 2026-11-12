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
    OpenUrl { url: String },
    Search { url: String },
    Command { id: String },
    Space { id: String },
    Folder { id: String, space_id: String },
    MoveToSpace { id: String },
    MoveToFolder { id: String, space_id: String },
    /// A page from the browser's history, supplied per query by the engine (D5). The core
    /// ranks it; Chromium's `HistoryService` is the only store.
    History { url: String },
}

impl Target {
    /// The order after the typed row (D2): open tabs, then history, then commands. The Space,
    /// Folder and Move rows the boards draw are filed with the commands, as they are commands.
    fn group(&self) -> u8 {
        match self {
            Target::Tab { .. } => 0,
            Target::History { .. } => 1,
            _ => 2,
        }
    }
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

/// One page of the browser's history, as the engine's `HistoryService` query returns it (D5).
/// `last_visit` is milliseconds since the epoch, or 0 when the engine does not report one.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryEntry {
    pub title: String,
    pub url: String,
    pub last_visit: u64,
}

pub trait Source {
    fn candidates(&self, query: &str) -> Vec<Suggestion>;
}

#[derive(Clone)]
struct Entry {
    suggestion: Suggestion,
    custom_title: bool,
    selected: Option<u64>,
}

pub struct Index {
    entries: Vec<(Entry, Option<SearchKey>)>,
    /// The shown space's most recent tabs, built once per open: the empty query's list (D4) is
    /// the same list the ⌃Tab switcher shows.
    recent: Vec<Suggestion>,
    now: u64,
    private_window: bool,
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
                            entries.push(Entry { suggestion: Suggestion { title: item.display_title().into(), subtitle: if pinned { format!("{} · Pinned", space.title) } else { space.title.clone() }, url: Some(url.clone()), key: None, target: Target::Tab { id: item.id.clone(), space_id: Some(space.id.clone()) }, score: 0.0 }, custom_title: item.title.is_some(), selected: ws.last_selected.get(&item.id).copied() });
                        }
                        ItemKind::Folder => {
                            for (title, target) in [(format!("Go to {}", item.display_title()), Target::Folder { id: item.id.clone(), space_id: space.id.clone() }), (format!("Move Tab to {}", item.display_title()), Target::MoveToFolder { id: item.id.clone(), space_id: space.id.clone() })] {
                                let skip = match &target { Target::MoveToFolder { id, .. } => !can_move_folder_to(space) || Some(id.as_str()) == current_folder.as_deref(), _ => false };
                                if skip { continue; }
                                entries.push(Entry { suggestion: Suggestion { title, subtitle: "Folder".into(), url: None, key: None, target, score: 0.0 }, custom_title: false, selected: None });
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
                        entries.push(Entry { suggestion: Suggestion { title: item.display_title().into(), subtitle: "Favorite".into(), url: Some(url.clone()), key: None, target: Target::Tab { id: item.id.clone(), space_id: None }, score: 0.0 }, custom_title: item.title.is_some(), selected: ws.last_selected.get(&item.id).copied() });
                    }
                }
            }
        }
        for binding in ws.key_bindings() {
            entries.push(Entry { suggestion: Suggestion { title: binding.command.title, subtitle: "Command".into(), url: None, key: binding.key, target: Target::Command { id: binding.command.id }, score: 0.0 }, custom_title: false, selected: None });
        }
        for space in &ws.spaces {
            for (title, target) in [(format!("Switch to {}", space.title), Target::Space { id: space.id.clone() }), (format!("Move Tab to {}", space.title), Target::MoveToSpace { id: space.id.clone() })] {
                if matches!(target, Target::Space { .. }) && Some(space.id.as_str()) == shown_space { continue; }
                if matches!(target, Target::MoveToSpace { .. }) && !can_move_to(space) { continue; }
                entries.push(Entry { suggestion: Suggestion { title, subtitle: "Space".into(), url: None, key: None, target, score: 0.0 }, custom_title: false, selected: None });
            }
        }
        if ws.is_private() { entries.retain(|entry| matches!(entry.suggestion.target, Target::Tab { .. } | Target::Command { .. })); }
        let entries = entries.into_iter().map(|entry| {
            let key = entry.suggestion.url.as_ref().map(|url| {
                let mut key = SearchKey::new(&entry.suggestion.title, url);
                let id = match &entry.suggestion.target { Target::Tab { id, .. } => Some(id), _ => None };
                key.saved_title = id.and_then(|id| ws.items.get(id)).and_then(|item| match &item.kind {
                    ItemKind::Tab { saved_title, .. } => saved_title.as_ref().map(|s| s.to_lowercase()), _ => None,
                });
                key
            });
            (entry, key)
        }).collect();
        Self { entries, recent: recent_tabs(ws, window, ROW_LIMIT), now, private_window: false }
    }

    /// A private window suggests no history and the bar shows the note (D7). The core withholds
    /// the rows itself, so a caller that passes history anyway cannot leak it.
    pub fn private_window(mut self, private: bool) -> Self {
        self.private_window = private;
        self
    }

    pub fn query(&self, query: &str, history: &[HistoryEntry]) -> CommandBarResult {
        let history = HistorySource::new(history, self.now);
        let sources: Vec<&dyn Source> = if self.private_window { vec![self] } else { vec![self, &history] };
        rank_result(query, &sources, self.private_window)
    }
}

impl Source for Index {
    fn candidates(&self, query: &str) -> Vec<Suggestion> {
        let q = query.to_lowercase();
        if q.is_empty() { return self.recent.clone(); }
        self.entries.iter().filter_map(|(e, key)| {
            let title = e.suggestion.title.to_lowercase();
            let score = if let Some(key) = key {
                let mut score = score_key(&q, key);
                if e.custom_title && title.starts_with(&q) { score += 40.0; }
                if score < 30.0 { return None; }
                score += recency_boost(e.selected.map(|at| self.now.saturating_sub(at)));
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
            let mut suggestion = e.suggestion.clone();
            suggestion.score = score;
            Some(suggestion)
        }).collect()
    }
}

/// The browser's history, one page per row (D5). Chromium's `HistoryService` owns the store;
/// the engine passes what its query returned and the core does the matching and the scoring.
pub struct HistorySource<'a> {
    entries: &'a [HistoryEntry],
    now: u64,
}

impl<'a> HistorySource<'a> {
    pub fn new(entries: &'a [HistoryEntry], now: u64) -> Self { Self { entries, now } }
}

impl Source for HistorySource<'_> {
    fn candidates(&self, query: &str) -> Vec<Suggestion> {
        let q = query.to_lowercase();
        if q.is_empty() { return Vec::new(); }
        self.entries.iter().filter_map(|entry| {
            let score = score_key(&q, &SearchKey::new(&entry.title, &entry.url));
            if score < 30.0 { return None; }
            let last_visit = (entry.last_visit > 0).then_some(entry.last_visit);
            Some(Suggestion {
                title: entry.title.clone(),
                subtitle: "History".into(),
                url: Some(entry.url.clone()),
                key: None,
                target: Target::History { url: entry.url.clone() },
                score: score + recency_boost(last_visit.map(|at| self.now.saturating_sub(at))),
            })
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

/// The age steps a tab and a history page share, so recent visits rank alike. A page never
/// selected or visited has no age and takes none.
fn recency_boost(age: Option<u64>) -> f64 {
    match age { Some(a) if a < 600_000 => 30.0, Some(a) if a < 3_600_000 => 22.0, Some(a) if a < 86_400_000 => 14.0, Some(a) if a < 604_800_000 => 7.0, _ => 0.0 }
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

/// The bar shows at most five rows, the typed row included (D1).
pub const ROW_LIMIT: usize = 5;

/// The empty query's list and the ⌃Tab switcher's list (D4): the shown space's most recently
/// selected tabs, newest first, with the selected tab and the shown split's members left out.
/// Unloaded tabs take part; favourites belong to the profile and do not.
pub fn recent_tabs(ws: &Workspace, window: &str, limit: usize) -> Vec<Suggestion> {
    let current = ws.selected(window);
    let current_split = current.and_then(|id| ws.outermost_split(id));
    let shown_space = ws.shown_space(window);
    let mut rows: Vec<(Option<u64>, Suggestion)> = Vec::new();
    for space in ws.spaces.iter().filter(|space| Some(space.id.as_str()) == shown_space) {
        for (root, pinned) in [(&space.pinned, true), (&space.today, false)] {
            let mut stack = ws.children(root).into_iter().rev().collect::<Vec<_>>();
            while let Some(item) = stack.pop() {
                if !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) { continue; }
                stack.extend(ws.children(&item.id).into_iter().rev());
                let ItemKind::Tab { url, .. } = &item.kind else { continue };
                if Some(item.id.as_str()) == current
                    || current_split.as_ref().is_some_and(|split| ws.outermost_split(&item.id).as_ref() == Some(split)) { continue; }
                rows.push((ws.last_selected.get(&item.id).copied(), Suggestion {
                    title: item.display_title().into(),
                    subtitle: if pinned { format!("{} · Pinned", space.title) } else { space.title.clone() },
                    url: Some(url.clone()), key: None,
                    target: Target::Tab { id: item.id.clone(), space_id: Some(space.id.clone()) },
                    score: 0.0,
                }));
            }
        }
    }
    rows.sort_by(|(a, _), (b, _)| b.cmp(a));
    rows.into_iter().take(limit).map(|(_, suggestion)| suggestion).collect()
}

pub fn rank(query: &str, sources: &[&dyn Source]) -> Vec<Suggestion> {
    rank_result(query, sources, false).rows
}

#[derive(Debug, Clone, PartialEq)]
pub struct CommandBarResult {
    pub rows: Vec<Suggestion>,
    /// The window is private: history rows are withheld and the bar shows its note (D7).
    pub private_window: bool,
}

/// The typed text is a row of its own and always first, even when an open tab matches (D1);
/// it counts inside the five. Behind it the rows follow D2's order: open tabs, history, then
/// commands (and the Space / Folder / Move rows filed with them), except that the one best
/// command whose title starts with the typed text at a word start takes the second row. Ties
/// keep source order.
pub fn rank_result(query: &str, sources: &[&dyn Source], private_window: bool) -> CommandBarResult {
    let query = query.trim();
    let mut results: Vec<_> = sources.iter().flat_map(|s| s.candidates(query)).collect();
    if query.is_empty() {
        results.truncate(ROW_LIMIT);
        return CommandBarResult { rows: results, private_window };
    }
    // Within a group the score decides; equal scores keep source order, so the commands stay in
    // the table's order and the first one below is the highest-scoring, then the earliest.
    results.sort_by(|a, b| a.target.group().cmp(&b.target.group()).then_with(|| b.score.total_cmp(&a.score)));
    let mut seen = HashSet::new();
    results.retain(|s| s.url.as_ref().is_none_or(|u| seen.insert(u.clone())));
    if let Some(index) = results.iter().position(|s| is_promoted_command(s, query)) {
        let promoted = results.remove(index);
        results.insert(0, promoted);
    }
    results.truncate(ROW_LIMIT.saturating_sub(1));
    results.insert(0, typed_row(query));
    CommandBarResult { rows: results, private_window }
}

/// D2's one exception: an exact command title must not be crowded out by weak tab matches, so
/// the best command that starts with the typed text goes right after the typed row. Only one is
/// promoted: nine `Show Space` rows ahead of every tab were the worse fault (review 2).
fn is_promoted_command(suggestion: &Suggestion, query: &str) -> bool {
    matches!(suggestion.target, Target::Command { .. }) && starts_with_at_word_start(&suggestion.title, query)
}

/// The title starts with the query, compared case-insensitively, or one of its words does: both
/// start at a word start, so `set` finds `Settings…` and `tab` finds `Close Tab` and `New Tab`.
fn starts_with_at_word_start(title: &str, query: &str) -> bool {
    let query = query.to_lowercase();
    if query.is_empty() { return false; }
    let title = title.to_lowercase();
    title.starts_with(&query) || title.split(|c: char| !c.is_alphanumeric()).any(|word| !word.is_empty() && word.starts_with(&query))
}

fn typed_row(query: &str) -> Suggestion {
    let url_like = looks_like_url(query);
    let target = if url_like {
        let host = query.split('/').next().unwrap_or("").split(':').next().unwrap_or("");
        let url = if query.contains("://") || query.starts_with("about:") || query.starts_with("file:") { query.to_string() } else if host == "localhost" || host.parse::<std::net::Ipv4Addr>().is_ok() { format!("http://{query}") } else { format!("https://{query}") };
        Target::OpenUrl { url }
    } else {
        Target::Search { url: search_url(query) }
    };
    Suggestion { title: query.into(), subtitle: if url_like { "Open URL" } else { "Search" }.into(), url: None, key: None, target, score: 0.0 }
}
