from parrotflow import recipe


@recipe(app="com.microsoft.Outlook", says="write an email to one or more people", needs=["who"])
def message_people(app, ask):
    if not ask.who:
        app.stop("nobody named")
    app.key("cmd+n", wait=1200)
    app.say("step       ⌘N")

    for name in ask.who:
        to = app.lookup_field()
        if not to:
            app.stop("the caret is not in a recipient field — stopping before typing anything")
        typed = name[:ask.letters]
        since = app.mark()
        app.type(typed)
        # Outlook's list is one of the app's other top-level parts, not the window.
        rows = app.rows(since=since, under=to, outside_window=True)
        if not rows:
            app.stop(f"typed “{typed}” and no list appeared")
        row = app.choose(f"Which of these rows is the person called “{name}”?", rows, typed=typed)
        if not row:
            app.stop(f"no row for {name}")
        app.click(row)
        app.wait(800)
        first = row.name.split(" ")[0].strip(",")
        if not app.on_line(first, to):
            app.stop(f"picked “{row.name[:30]}” and it is not on the recipient line")
        app.say(f"           {first} is in")

    subject = [e for e in app.find(kind="text", name="subject")]
    if not subject:
        app.stop("everyone is in, but there is no subject field")
    app.say(f"done       {len(ask.who)} of {len(ask.who)} recipients")
    app.ready(subject[0])
