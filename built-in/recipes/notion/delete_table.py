from parrotflow import recipe


@recipe(app="notion.id", says="delete a table from the page", allows=["delete"])
def delete_table(app, ask):
    bottom = ask.screen["h"]
    tables = [t for t in app.frames("AXTable") if t.h > 10 and t.top < bottom - 20]
    if not tables:
        app.stop("no table on screen")
    table = tables[0]
    if ask.gaze:
        gx, gy = ask.gaze
        table = min(tables, key=lambda t: (t.x - gx) ** 2 + (t.y - gy) ** 2)
    app.say(f"table      {int(table.left)},{int(table.top)} {table.w}x{table.h}, of {len(tables)} on screen")

    def still_there():
        return any(abs(t.left - table.left) < 4 and abs(t.top - table.top) < 4 and abs(t.h - table.h) < 4
                   for t in app.frames("AXTable"))

    # A drag from just outside the table to just outside it selects the block,
    # not its cells. Small margins, so the blocks around it are not caught.
    start = (table.left - 24, table.top - 6)
    end = (table.right + 24, table.bottom + 6)
    app.drag(start, end)
    app.wait(300)
    app.key("delete", wait=700)
    app.say(f"step       dragged {int(start[0])},{int(start[1])} → {int(end[0])},{int(end[1])} and pressed Delete")
    if not still_there():
        app.done("deleted the table — ⌘Z undoes it")
    app.say("           the table is still there — trying its menu")

    # Accessibility's "show menu" reports success here and opens nothing, so:
    # a right-click, then the ⋮⋮ handle, which is only in the tree on hover.
    spot = (table.x, min(table.top + 20, bottom - 30))
    items = []
    for attempt in (1, 2):
        since = app.mark(at=spot)
        if attempt == 1:
            app.right_click(*spot)
            app.say("step       right-clicked the table")
        else:
            app.hover(table.left + 30, table.top + 18)
            app.wait(450)
            handle = None
            for dx in range(6, 91, 6):
                handle = app.pressable_at(table.left - dx, table.top + 18)
                if handle:
                    break
            if not handle:
                app.stop("hovered the table and found no handle to its left")
            app.click_at(handle.x, handle.y)
            app.say(f"step       hovered, clicked the handle at {int(handle.x)},{int(handle.y)}")
        items = app.appeared(since=since, ms=2000, windows=True)
        # A block menu has more than one choice in it.
        if len(items) >= 3:
            break
        app.say(f"           {len(items)} item(s) appeared — not the block menu")
        app.key("escape", wait=300)
        items = []

    if not items:
        app.stop("neither way opened the block menu")
    delete = app.choose("Which of these menu items deletes the block?", items, typed="menu")
    if not delete:
        app.key("escape")
        app.stop("no menu item deletes the block")
    app.click(delete)
    app.wait(700)
    if still_there():
        app.stop(f"clicked “{delete.name[:30]}” and the table is still there")
    app.done("deleted the table — ⌘Z undoes it")
