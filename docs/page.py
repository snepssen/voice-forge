"""Voice Forge's page, as content.

The chrome — head, rail, header, jump navigation, ecosystem grid, footer —
is build.py's, shared byte-identically with every other project here. What is
in this file is what belongs to this page alone.

Each section names an HTML partial under `sections/`, so its markup stays
markup in a file an editor understands. build.py also takes structured blocks,
which siphon's page uses, for content regular enough to be worth it.
"""

PAGE = {
    "meta": {
        "slug": "voice-forge",
        "name": "Voice&nbsp;Forge",
        "title": "Voice Forge",
        "license": "GPL-3.0",
        "fonts": "fonts.css",
        "description": "A text-to-speech tool with the synthesiser’s dials on the outside, built on a voice trained from about forty minutes of my own speech.",
        "og_description": None,
        "contact_note": 'There’s no updater and no crash reporter, which is deliberate — and it means a failure has no way of reaching me on its own. The app has a Help sheet that copies its version, platform and voices to the clipboard for you to read before you send it. Your script and your dictionary are never in it.',
        "subhead": "A text-to-speech tool with the synthesiser’s dials on the outside — built on a voice trained from about forty minutes of my own speech.",
        "stats": [
            "<b>One bundled voice</b> · 22,050 Hz",
            "<b>~30×</b> realtime",
            "<b>No network.</b> Enforced at the socket layer",
            "<b>280</b> checks across two implementations",
        ],
        "scripts": ["site.js"],
        "header_extra": "header.html",
    },
    "sections": [
    {
        "eyebrow": "Why it exists",
        "heading": "The interesting part isn’t the voice. It’s the timing.",
        "body": "01.html",
    },
    {
        "eyebrow": "Measured",
        "heading": "What a comma is worth",
        "id": "comma",
        "fold": True,
        "teaser": 'Piper has no pause table, so each mark was measured: a comma is 145 ms on the bundled voice, and three times that on another.',
        "body": "02.html",
    },
    {
        "id": "screenshots",
        "jump": "Screenshots",
        "eyebrow": "The app",
        "heading": "Dials, and what they cost",
        "body": "screenshots.html",
    },
    {
        "eyebrow": "Three things it does that other tools don’t",
        "heading": "Pauses, pronunciation, and an honest export",
        "id": "controls",
        "fold": True,
        "teaser": "Pauses in honest units, an IPA dictionary checked against the voice's own symbols, and an export that says what it did.",
        "body": "04.html",
    },
    {
        "id": "downloads",
        "jump": "Downloads",
        "eyebrow": "Downloads",
        "heading": "Get it",
        "body": "downloads.html",
    },
    {
        "eyebrow": "Your own voice",
        "heading": "The app will use any Piper voice you give it",
        "id": "voices",
        "fold": True,
        "teaser": 'Drop in any Piper voice, or train one on your own speech; the steps that decide whether it sounds like you.',
        "body": "06.html",
    },
    {
        "eyebrow": "How it’s built",
        "heading": "Two implementations, one set of measurements",
        "id": "engines",
        "fold": True,
        "teaser": 'Swift on the Mac, Electron elsewhere, and a parity suite holding the two engines to the same answers.',
        "body": "07.html",
    },
    {"folds": True},
    {"grid": True},
    ],
    "footer": [
        "Voice Forge · one bundled voice, trained on about forty minutes of my own speech ·\n  built with Piper/VITS, ONNX Runtime and espeak-ng.",
    ],
}
