use serde::{Deserialize, Serialize};

use crate::model::{Id, Profile};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MatchStyle {
    Contains,
    Equals,
}

impl Default for MatchStyle {
    fn default() -> Self {
        // Contains is Arc's style on a fresh rule (Cra LinkRouting.swift: match defaults to .contains).
        MatchStyle::Contains
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UrlCondition {
    pub style: MatchStyle,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SpaceTarget {
    MostRecent,
    Space(Id),
}

// The default is the Little window with the profile's own tabs, the value Arc's
// StorableLinkRouting.json carried for the owner's default destination (and Cra imports
// as .littleWindow); the Settings pane can point it at a space instead.
impl Default for Destination {
    fn default() -> Self {
        Destination::LittleWindow(Profile::Default)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Destination {
    Space(SpaceTarget),
    LittleWindow(Profile),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rule {
    pub id: Id,
    pub conditions: Vec<UrlCondition>,
    pub destination: Destination,
}

// A rule between records carries its fractional order key the way item memberships do:
// the record body stores `{order, conditions, destination}` and the rule id is the record's
// key, so this form exists to move the three fields around with `Rule`.
#[derive(Serialize, Deserialize)]
pub struct StoredRuleBody {
    pub order: String,
    pub conditions: Vec<UrlCondition>,
    pub destination: Destination,
}

// A rule as the workspace carries it in memory: the order key beside the rule it positions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredRule {
    pub order: String,
    pub rule: Rule,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Routing {
    pub rules: Vec<Rule>,
    pub default: Destination,
}

impl Default for Routing {
    fn default() -> Self {
        // Where links from other apps go on a fresh install: the Little window (Arc's default
        // file and Cra's import default are the Little window; the Settings pane can point
        // it at a space).
        Routing { rules: Vec::new(), default: Destination::default() }
    }
}

// Rules read in their record order, which the workspace derives per record (architecture 8.3):
// two devices holding the same records read the same rule order, so a link goes the same way.
impl Routing {
    // The destination a URL from another app lands on: the first rule with a matching
    // condition, else the default. A destination naming a space the workspace no longer has
    // still answers — the rule matches (rule_for) — and the link goes to the most recent
    // space instead, so the stale id never reaches a window. The stored destinations stay
    // untouched, which the Settings pane reads for its deleted-space menus; the rewrite is
    // why the answer is an owned value.
    pub fn route(&self, url: &str, spaces: &[Id]) -> Destination {
        let destination = self.rule_for(url).map_or(&self.default, |rule| &rule.destination);
        match destination {
            Destination::Space(SpaceTarget::Space(id)) if !spaces.iter().any(|space| space == id) =>
                Destination::Space(SpaceTarget::MostRecent),
            _ => destination.clone(),
        }
    }

    // The rule a URL takes: the first rule with a matching condition. route() is this plus
    // its destination, so callers that need the rule id never match a second time.
    pub fn rule_for(&self, url: &str) -> Option<&Rule> {
        let url = normalize(url);
        // shortcut: a rule matches when any condition matches; Arc's meaning for several conditions is unobserved, recheck once Yab/Arc show a multi-condition rule.
        self.rules.iter().find(|rule| rule.conditions.iter().any(|c| c.matches(&url)))
    }
}

impl UrlCondition {
    fn matches(&self, url: &str) -> bool {
        let text = normalize(&self.text);
        // Why not match an empty condition: `contains("")` would match every URL; an empty
        // route matches nothing (Cra LinkRouting.swift, verified on Arc 1.170).
        if text.is_empty() { return false; }
        match self.style {
            MatchStyle::Contains => url.contains(&text),
            MatchStyle::Equals => host_and_path(url) == host_and_path(&text),
        }
    }
}

fn normalize(s: &str) -> String {
    let s = s.trim().to_lowercase();
    let s = match s.split_once("://") {
        Some((scheme, rest)) if is_scheme(scheme) => rest,
        _ => s.as_str(),
    };
    s.strip_prefix("www.").unwrap_or(s).to_string()
}

// RFC 3986: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
fn is_scheme(s: &str) -> bool {
    let mut chars = s.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
}

fn host_and_path(normalized: &str) -> &str {
    let end = normalized.find(['?', '#']).unwrap_or(normalized.len());
    normalized[..end].trim_end_matches('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn routing(style: MatchStyle, text: &str) -> Routing {
        Routing {
            rules: vec![Rule {
                id: "r".into(),
                conditions: vec![UrlCondition { style, text: text.into() }],
                destination: Destination::Space(SpaceTarget::Space("work".into())),
            }],
            default: Destination::LittleWindow(Profile::Default),
        }
    }

    fn goes_to_work(r: &Routing, url: &str) -> bool {
        r.route(url, &["work".into()]) == Destination::Space(SpaceTarget::Space("work".into()))
    }

    #[test]
    fn an_empty_condition_matches_nothing() {
        let r = routing(MatchStyle::Contains, "");
        assert!(!goes_to_work(&r, "https://example.com/"));
        let r = routing(MatchStyle::Equals, "   ");
        assert!(!goes_to_work(&r, "https://example.com/"));
        // A whitespace-only condition falls back to the default on the same call.
        assert_eq!(r.route("https://example.com", &["work".into()]), r.default);
    }

    #[test]
    fn contains_ignores_case_scheme_and_www_and_sees_query() {
        let r = routing(MatchStyle::Contains, "Meet.Google.com");
        assert!(goes_to_work(&r, "https://www.meet.google.com/abc"));
        let r = routing(MatchStyle::Contains, "ref=mail");
        assert!(goes_to_work(&r, "https://example.com/a?ref=mail#top"));
    }

    #[test]
    fn contains_keeps_a_scheme_inside_the_condition() {
        let r = routing(MatchStyle::Contains, "redirect=https://example.com");
        assert!(!goes_to_work(&r, "https://example.com/plain"));
        assert!(goes_to_work(&r, "https://login.example.org/?redirect=https://example.com"));
    }

    #[test]
    fn equals_compares_host_and_path_only() {
        let r = routing(MatchStyle::Equals, "https://github.com/pulls/");
        assert!(goes_to_work(&r, "http://www.github.com/pulls?q=1#x"));
        assert!(!goes_to_work(&r, "https://github.com/pulls/assigned"));
    }

    #[test]
    fn falls_back_to_default_and_first_rule_wins() {
        let mut r = routing(MatchStyle::Contains, "example.com");
        r.rules.push(Rule {
            id: "later".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "example".into() }],
            destination: Destination::Space(SpaceTarget::MostRecent),
        });
        assert!(goes_to_work(&r, "https://example.com"));
        assert_eq!(r.route("https://other.org", &["work".into()]), Destination::LittleWindow(Profile::Default));
    }
}
