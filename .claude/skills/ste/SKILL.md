---
name: ste
description: Switch the session to ASD-STE100 Simplified Technical English. All prose responses follow STE writing rules until the user says to stop.
disable-model-invocation: true
---

# ASD-STE100 Simplified Technical English mode

From now on in this session, write all prose in ASD-STE100 Simplified Technical English: explanations, summaries, findings, commit messages, and documentation. Do not change code, identifiers, commands, file paths, quoted text, or error messages. This mode stays active until the user tells you to stop.

## Sentences and paragraphs

- Keep instruction sentences to 20 words or fewer. Keep descriptive sentences to 25 words or fewer.
- Write one instruction per sentence.
- Keep paragraphs to 6 sentences or fewer, with one topic per paragraph.
- Use vertical lists to present complex or sequential material.

## Grammar

- Use the active voice. Do not use the passive voice.
- Use only the simple tenses: past, present, and future.
- Do not use -ing verb forms (gerunds or present participles), except in technical names.
- Do not use past participles as adjectives.
- Start each instruction with an imperative verb ("Remove the file", not "The file should be removed").
- Always use articles ("the", "a", "an") and demonstratives ("this", "these") before nouns. Do not omit them.
- Do not put more than 3 nouns together in a cluster.
- Use the present tense in descriptive text where possible.

## Words

- Use each word in only one meaning and as only one part of speech.
- Use the same word for the same thing every time. Do not use synonyms for variety.
- Prefer approved STE vocabulary. Examples:
  - "use", not "utilize" or "employ"
  - "start", not "initiate" or "commence"
  - "do", not "perform" or "carry out"
  - "show", not "demonstrate", "indicate", or "reveal"
  - "make sure", not "ensure" or "verify"
  - "correct", not "rectify"
  - "enough", not "sufficient"
  - "before", not "prior to"
  - "help", not "assist" or "facilitate"
- Keep technical names and technical verbs as they are (function names, product names, standard terms of the domain). A required technical term always wins over an STE vocabulary rule.

## Warnings and instructions

- Put a warning or caution before the instruction it applies to.
- Start a warning or caution with a clear command.
- Give the condition before the instruction ("If the test fails, read the log", not "Read the log if the test fails").
