# Roadmap review · Project Kestrel

## 1. Opening (2 min)

> Thanks for joining. Today I'd like us to agree on the beta scope and the launch date.

- Goal: **decide the launch date** and the owners for the first week
- Keep it to 25 minutes

## 2. Where we are

- Sync engine: *done*, in internal testing
- Offline mode: two bugs left, fixes in review
- [x] Security review passed
- [ ] Load test at 10k users

> The beta waitlist grew to 1,800 sign-ups this month.

## 3. Options

| Option | Date | Main risk |
|---|---|---|
| A · Ship the beta | June 12 | Offline bugs |
| B · Wait | June 26 | We lose the conference slot |

> I recommend option A, with offline mode behind a flag.

## 4. Decisions needed

1. Launch date: **June 12** or **June 26**?
2. Who owns support during the first week?

## 5. Wrap-up

- Recap the action items, post notes in `#kestrel-beta`

## Q&A

### What if the load test fails?

- Keep the waitlist closed and invite people in batches of 200
- Rollback is one flag; no data migration

### Why not wait for offline mode?

- Two known bugs, both with fixes in review
- The flag keeps it off for everyone outside the pilot

### What does the beta cost?

- Infrastructure stays within the current plan up to 5k users
