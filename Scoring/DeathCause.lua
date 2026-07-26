-- Death-cause classification (Josh 2026-07-25). A death recap is the
-- last ~5 hits before a player died (`{ t, spell, amount, avoidable }`,
-- oldest first, killing blow last — Metrics/Taken.lua). This turns that
-- into a CAUSE the coach can name: was it an avoidable mechanic, a
-- tankbuster, a one-shot, or chip damage (a healing gap)?
--
-- Two avoidable signals coexist by design and must not double-count:
--   * the SCORING avoidable penalty runs off the aggregated
--     m.avoidableTaken metric (share-relative, capped) — Engine.lua.
--   * DeathCause avoidable EXPLAINS a death for coaching only; it adds
--     NO points. So a false positive here costs nobody anything.
--
-- Accuracy scales with data: with a crawled TP.DAMAGE_PROFILES entry
-- for the boss (per-ability hitRate/tankOnly/hitPct), classification is
-- sharp. WITHOUT one it degrades to the one-shot rule + the per-hit
-- `avoidable` flag — i.e. today's behavior — so there is no regression
-- on uncrawled or early-tier bosses.
-- PURE: no WoW API; headless-tested in tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local DeathCause = {}
TP.Scoring.DeathCause = DeathCause

-- Tunable thresholds (asserted in tests so a retune is deliberate).
local T = {
	oneShotHP = 0.9, -- a hit this fraction of max HP is unavoidable-once-hit
	avoidableHitRate = 0.4, -- abilities <40% of players take are dodgeable
	contributorShare = 0.30, -- a hit worth this much of the recap can name the death
	dominantShare = 0.60, -- a single hit this big means it wasn't chip
	tankbusterHitPct = 0.6, -- a tank-only hit landing this hard is a buster
	tankbusterShare = 0.40,
}
DeathCause.THRESHOLDS = T

-- Resolve the crawled profiles for a fight: encounterID first (locale-
-- proof), then the stripped name — the standard Percentiles pattern.
function DeathCause.ProfilesFor(fight)
	local P = TP.DAMAGE_PROFILES
	if not (P and fight) then
		return nil
	end
	if fight.encounterID and P.ids and P.ids[fight.encounterID] then
		return P[P.ids[fight.encounterID]]
	end
	if fight.name then
		return P[(fight.name:gsub("^%(!%)%s*", ""))]
	end
end

-- Classify ONE death. Returns { category, spell, share, forgive } where
-- category is one of: oneShot | tankbuster | avoidable | chip | unknown.
--   forgive = true means "the player could not have prevented this once
--   it was incoming" (one-shots) — the engine forgives defensive
--   penalties for these, exactly as it does today.
function DeathCause.Classify(deathRecap, maxHP, profiles)
	if not deathRecap or #deathRecap == 0 then
		return { category = "unknown" }
	end
	local total, biggest, biggestHit = 0, 0, nil
	for _, hit in ipairs(deathRecap) do
		local amt = hit.amount or 0
		total = total + amt
		if amt > biggest then
			biggest, biggestHit = amt, hit
		end
	end
	local killingBlow = deathRecap[#deathRecap]

	-- 1) one-shot: any single hit >= 90% of max HP (mirrors Engine.lua's
	-- existing rule so the two stay in sync). Highest priority.
	if maxHP and maxHP > 0 then
		for _, hit in ipairs(deathRecap) do
			if (hit.amount or 0) >= maxHP * T.oneShotHP then
				return { category = "oneShot", spell = hit.spell, forgive = true }
			end
		end
	end

	local function prof(spell)
		return profiles and spell and profiles[spell] or nil
	end

	-- 2) tankbuster: the killing blow is a hard tank-only hit the player
	-- should have pre-mitigated (not forgiven — that's the skill).
	local kbP = prof(killingBlow.spell)
	if kbP and kbP.tankOnly and (kbP.hitPct or 0) >= T.tankbusterHitPct
		and total > 0 and (killingBlow.amount or 0) >= total * T.tankbusterShare then
		return { category = "tankbuster", spell = killingBlow.spell,
			share = (killingBlow.amount or 0) / total }
	end

	-- 3) avoidable: the killing blow OR any hit contributing >= 30% of the
	-- recap is "dodgeable" — profile hitRate < 0.4 (good players avoid it)
	-- OR the per-hit avoidable flag (the fallback signal that works with
	-- no profile).
	for _, hit in ipairs(deathRecap) do
		local isKB = hit == killingBlow
		local shareOf = total > 0 and (hit.amount or 0) / total or 0
		if isKB or shareOf >= T.contributorShare then
			local hp = prof(hit.spell)
			local dodgeable = hit.avoidable
				or (hp and hp.hitRate and hp.hitRate < T.avoidableHitRate)
			if dodgeable then
				return { category = "avoidable", spell = hit.spell, share = shareOf }
			end
		end
	end

	-- 4) chip: no single hit dominates (the 84%-of-deaths pile-on case) —
	-- a healing gap or slow reaction, NOT necessarily the dead player's
	-- fault. 5) otherwise a dominant unprofiled non-avoidable hit: unknown.
	if total > 0 and biggest < total * T.dominantShare then
		return { category = "chip" }
	end
	return { category = "unknown", spell = biggestHit and biggestHit.spell }
end

-- Aggregate a fight's classified deaths for the raid coach / salience.
function DeathCause.Summarize(classified)
	local out = { oneShot = 0, tankbuster = 0, avoidable = 0, chip = 0,
		unknown = 0, total = 0 }
	for _, c in ipairs(classified or {}) do
		local cat = c.category or "unknown"
		out[cat] = (out[cat] or 0) + 1
		out.total = out.total + 1
	end
	return out
end
