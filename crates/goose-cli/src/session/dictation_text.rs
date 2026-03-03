use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DictationInsertion {
    pub merged_text: String,
    pub auto_submit: bool,
}

/// Applies voice-dictation transcript text to an existing input buffer.
///
/// Behavior intentionally mirrors desktop voice dictation:
/// - strips parenthesized asides (e.g. "(background noise)")
/// - trims whitespace
/// - treats standalone cancel/discard phrases as no-op safety cancels
/// - detects a trailing "submit" command (case-insensitive, with trailing punctuation)
/// - strips that trailing submit marker from inserted text
/// - appends to existing input with a single space
pub(crate) fn apply_dictation_transcript(
    existing_input: &str,
    transcript: &str,
) -> Option<DictationInsertion> {
    let filtered_text = parenthetical_re().replace_all(transcript, "");
    let filtered_text = filtered_text.trim();

    // Match desktop behavior: ignore empty transcript after parenthetical cleanup.
    if filtered_text.is_empty() {
        return None;
    }

    // Safety control: treat standalone cancel/discard directives as no-op.
    if discard_only_re().is_match(filtered_text) {
        return None;
    }

    let should_auto_submit = submit_suffix_re().is_match(filtered_text);
    let cleaned_text = if should_auto_submit {
        submit_suffix_re()
            .replace(filtered_text, "")
            .trim()
            .to_string()
    } else {
        filtered_text.to_string()
    };

    let existing = existing_input.trim();
    let merged_text = if !existing.is_empty() && !cleaned_text.is_empty() {
        format!("{} {}", existing, cleaned_text)
    } else if !existing.is_empty() {
        existing.to_string()
    } else {
        cleaned_text
    };

    Some(DictationInsertion {
        auto_submit: should_auto_submit && !merged_text.is_empty(),
        merged_text,
    })
}

fn parenthetical_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\([^)]*\)").expect("valid parenthetical regex"))
}

fn submit_suffix_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)\bsubmit[.,!?;'\"\s]*$").expect("valid submit suffix regex")
    })
}

fn discard_only_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i)^(?:cancel(?:\s+that)?|discard(?:\s+that)?|never\s*mind(?:\s+that)?|scratch\s+that)[.,!?;'\"\s]*$",
        )
        .expect("valid discard regex")
    })
}

#[cfg(test)]
mod tests {
    use super::{apply_dictation_transcript, DictationInsertion};

    #[test]
    fn strips_parentheticals_and_appends_text() {
        let out = apply_dictation_transcript("draft", "(background noise) hello world").unwrap();
        assert_eq!(
            out,
            DictationInsertion {
                merged_text: "draft hello world".to_string(),
                auto_submit: false
            }
        );
    }

    #[test]
    fn detects_submit_suffix_and_strips_it() {
        let out = apply_dictation_transcript("", "Ship this please, submit!!!").unwrap();
        assert_eq!(
            out,
            DictationInsertion {
                merged_text: "Ship this please".to_string(),
                auto_submit: true
            }
        );
    }

    #[test]
    fn submit_only_auto_submits_existing_input() {
        let out = apply_dictation_transcript("run targeted tests", "submit").unwrap();
        assert_eq!(
            out,
            DictationInsertion {
                merged_text: "run targeted tests".to_string(),
                auto_submit: true
            }
        );
    }

    #[test]
    fn empty_after_filter_is_ignored() {
        assert!(apply_dictation_transcript("existing", " (noise) ").is_none());
    }

    #[test]
    fn submit_only_with_no_existing_input_does_not_auto_submit() {
        let out = apply_dictation_transcript("", "SUBMIT...").unwrap();
        assert_eq!(
            out,
            DictationInsertion {
                merged_text: "".to_string(),
                auto_submit: false
            }
        );
    }

    #[test]
    fn standalone_cancel_is_ignored() {
        assert!(apply_dictation_transcript("draft", "cancel!!!").is_none());
        assert!(apply_dictation_transcript("draft", "cancel that").is_none());
        assert!(apply_dictation_transcript("draft", "discard that.").is_none());
        assert!(apply_dictation_transcript("draft", "never mind").is_none());
        assert!(apply_dictation_transcript("draft", "nevermind that").is_none());
        assert!(apply_dictation_transcript("draft", "scratch that").is_none());
    }

    #[test]
    fn cancel_word_inside_sentence_is_not_ignored() {
        let out =
            apply_dictation_transcript("", "cancel the old plan and write a new one").unwrap();
        assert_eq!(
            out,
            DictationInsertion {
                merged_text: "cancel the old plan and write a new one".to_string(),
                auto_submit: false
            }
        );

        let out = apply_dictation_transcript("", "scratch that old section, keep the rest").unwrap();
        assert_eq!(
            out,
            DictationInsertion {
                merged_text: "scratch that old section, keep the rest".to_string(),
                auto_submit: false
            }
        );
    }
}
