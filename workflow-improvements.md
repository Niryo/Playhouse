# Workflow Improvements

- Task `643B7C51-5D54-4652-B32B-90B5FF02B681`: The task card showed 2m03s from creation to an in-progress snapshot, not total task duration. Check conversation/tool timestamps and existing task-event records for phase and completion times; add logging only for intervals those sources do not capture, then verify coverage on the next task.
