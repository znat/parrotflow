from parrotflow import recipe


# @recipe(
#     app="com.tinyspeck.slackmacgap",
#     says="write a message to one or more people",
#     needs=["who"],
# )
# def message_people(app, ask):
#     if not ask.who:
#         app.stop("nobody named")
#     app.key("cmd+n", wait=1200)
#     app.say("step       ⌘N")

#     for name in ask.who:
#         to = app.lookup_field()
#         if not to:
#             app.stop("the caret is not in a recipient field — stopping before typing anything")
#         typed = name[:ask.letters]
#         since = app.mark()
#         app.type(typed)
#         rows = app.rows(since=since, under=to)
#         if not rows:
#             app.stop(f"typed “{typed}” and no list appeared")
#         row = app.choose(f"Which of these rows is the person called “{name}”?", rows, typed=typed)
#         if not row:
#             app.stop(f"no row for {name}")
#         app.click(row)
#         app.wait(800)
#         first = row.name.split(" ")[0].strip(",")
#         if not app.on_line(first, to):
#             app.stop(f"picked “{row.name[:30]}” and it is not on the recipient line")
#         app.say(f"           {first} is in")

#     boxes = app.find(role="AXTextArea")
#     if not boxes:
#         app.stop("everyone is in, but there is no message box")
#     app.say(f"done       {len(ask.who)} of {len(ask.who)} recipients")
#     app.ready(max(boxes, key=lambda b: b.w * b.h))
