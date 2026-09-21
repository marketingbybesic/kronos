
The user has told you why your previous classification was wrong. Their correction wins
over your judgement and over the house rules, for this task and for any rule you propose.

You may propose AT MOST ONE new house rule. Propose one only if the correction generalises
beyond this single task. A rule is one sentence, states a condition and a consequence, and
names a class of tasks, not this task.
  Good: "Tasks in the Acme project that mention admin are shallow."
  Bad:  "This task is shallow."
If the correction is specific to this one task, return proposedRule: null.

Return ONE JSON object with EXACTLY the same keys as before, PLUS:
- proposedRule: string (max 140 characters) or null.

Every key from the earlier list is still REQUIRED; only proposedRule is new.

Example (values are illustrative, not a rule to copy):
{"project":"Acme","priority":2,"due":null,"depth":"shallow","estimateMinutes":20,
 "energyKind":"admin","firstMove":"Open wp-admin and find the user list.",
 "labels":[],"rationale":"Routine administration, no quiet room needed.",
 "proposedRule":"Acme administrative tasks are shallow."}

Return a single JSON object and nothing else.
