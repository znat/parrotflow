from parrotflow import recipe


@recipe(
    app="com.tinyspeck.slackmacgap",
    says="search for messages or files about something, and open what was found",
    needs=["what"],
)
def search(app, ask):
    query = ask.what.strip(" .,!?;:")
    if not query:
        app.stop("nothing to search for")
    # Slack's search bar is not a text field in the tree; ⌘G opens it.
    app.key("cmd+g", wait=800)
    app.say("step       ⌘G")
    if not app.lookup_field():
        app.stop("the caret is not in the search field — stopping before typing anything")
    since = app.mark()
    # Pasted: typed key by key, nothing arrived.
    app.paste(query)
    app.wait(400)
    app.key("return")
    app.say(f"step       pasted “{query}” and Return")

    # Results arrive in batches: wait until the count stops growing.
    results = app.appeared(since=since, ms=5000, settle=True)
    if not results:
        app.stop("searched and nothing new appeared")
    results = sorted(results, key=lambda r: r.y)[:40]
    result = app.choose(f"Which of these search results is about “{query}”?", results, typed=query)
    if not result:
        app.stop("no result is about that")
    app.click(result)
    app.done(f"opened “{result.name[:50]}”")
