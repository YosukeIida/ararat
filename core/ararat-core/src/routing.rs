use crate::model::{Id, Profile};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchStyle {
    Contains,
    Equals,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UrlCondition {
    pub style: MatchStyle,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SpaceTarget {
    MostRecent,
    Space(Id),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Destination {
    Space(SpaceTarget),
    LittleWindow(Profile),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub id: Id,
    pub conditions: Vec<UrlCondition>,
    pub destination: Destination,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Routing {
    pub rules: Vec<Rule>,
    pub default: Destination,
}

impl Routing {
    pub fn route(&self, url: &str) -> &Destination {
        let url = normalize(url);
        self.rules
            .iter()
            // shortcut: a rule matches when any condition matches; Arc's meaning for several conditions is unobserved, recheck once Yab/Arc show a multi-condition rule.
            .find(|rule| rule.conditions.iter().any(|c| c.matches(&url)))
            .map_or(&self.default, |rule| &rule.destination)
    }
}

impl UrlCondition {
    fn matches(&self, url: &str) -> bool {
        let text = normalize(&self.text);
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
        *r.route(url) == Destination::Space(SpaceTarget::Space("work".into()))
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
        assert_eq!(*r.route("https://other.org"), Destination::LittleWindow(Profile::Default));
    }
}
