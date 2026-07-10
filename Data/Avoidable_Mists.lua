-- Avoidable damage sources, MoP Classic (the "Stood in bad" penalty).
-- Anything listed here counts toward a player's avoidable-damage share.
-- SAFETY: the engine only penalizes damage BEYOND an equal share of the
-- group's total from these spells - a mechanic the whole raid eats equally
-- can never hurt anyone's score, so a borderline entry fails soft.
-- Curate with /tp baddies after a raid night: it prints the session's top
-- damage-taken spells with their IDs. Verify IDs against Warcraft Logs
-- before adding (wrong IDs = unfair penalties; see the Blood Pact lesson).
local _, TP = ...

TP.AVOIDABLE = {
	-- Siege of Orgrimmar: to be filled from /tp baddies + WCL review.
	-- e.g. [143412] = true, -- Immerseus: Swirl
}
