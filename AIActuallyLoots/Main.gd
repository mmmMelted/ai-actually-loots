extends Node
## AI Actually Loots: makes Road to Vostok's AI loot, as the game intends.
##
## Why: the game has AI looting code (Wander -> GetLootPoint -> Loot -> LootContainer.AILoot), but it never finds
## anything: the AI's loot detection area has no collision mask and containers have no area to detect, so
## GetLootPoint() always returns false. This mod finds targets itself and hands them to the game's own looting.
##
## - Calm AI (not alerted or fighting) walk to nearby containers and take 1-3 items into their own inventory (you find
##   them on the body), only what fits their inventory grid. Bandits loot often; Guards and Military only very rarely
##   (about once per 5 / 10 calm minutes); Nomads never loot.
## - Full AI keep looting by trading up: they swap their cheapest item for a clearly more valuable one, leaving the
##   cheap one in the container (or on the floor when it doesn't fit there).
## - Loot sound volume and trading up are set in Mod Configuration Menu (MCM) when installed, otherwise in
##   user://MCM/AIActuallyLoots/config.ini.
## - Hiders (AI waiting in ambush in houses) loot the house instead of standing still, return to their hide spot, and
##   drop everything to get back into ambush the moment something approaches.
## - After a kill, the killer loots the body once things calm down; other calm AI scavenge fresh bodies nearby
##   (bandits loot anyone, others only enemies).
## - Fixes vanilla Loot() sending an AI back to wandering when its loot animation ends, even mid-fight.
## Bosses are left alone. Works on its own or alongside other AI mods.


const VERSION := "1.2.0"
const TAG := "[AIActuallyLoots] "


const CHECK_INTERVAL := Vector2(2.0, 4.0)
const LOOT_RANGE := 35.0
const HOUSE_RANGE := 15.0
const CORPSE_RANGE := 50.0
const CORPSE_FRESH := 900.0
const ITEMS_PER_VISIT := Vector2i(1, 3)
const CARRY_LIMIT := 10
const TASK_TIMEOUT := 45.0
const VISIT_FORGET := 600.0
const RESERVE_TIME := 40.0
const HOME_RANGE := 20.0
## After a container, keep searching unchecked containers this close (same room/house) for SEARCH_ON_TIME s.
const SEARCH_ON := 10.0
const SEARCH_ON_TIME := 6.0
## Pause between grabbing items from an open container.
const GRAB_TIME := 0.6
## Where an AI stands to loot: this far from the container, on a side with a clear line to it.
const APPROACH_DIST := 0.9
const BOTS_PER_FRAME := 2
## Chance per check to go looting when calm, by faction. Hiders use at least HIDER_WILL.
## Checks come every ~3 s while calm: Guards loot about once per 5 calm minutes, Military about once per 10.
const WILL := {AIData.Faction.Bandit: 0.5, AIData.Faction.Guard: 0.01, AIData.Faction.Military: 0.005}
const HIDER_WILL := 0.85
## Trading up: take a container item only if it's worth at least SWAP_RATIO times, and SWAP_MIN more than, the
## carried item it replaces (so AI don't shuffle near-equal items back and forth).
const SWAP_RATIO := 1.5
const SWAP_MIN := 10.0


const MCM_HELPERS := "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"
const MCM_ID := "AIActuallyLoots"
const MCM_DIR := "user://MCM/AIActuallyLoots"
const MCM_FILE := "config.ini"


var _lib = null
## 0..1, applied to the game's own loot sounds (open container, pick up item).
var _volume := 0.5
var _swap := true
var _containers := []
var _corpses := []
var _bots := []
var _botsT := -100.0
var _tickIndex := 0



func _ready():
	_load_config()
	print(TAG + "v" + VERSION + " loaded (loot volume " + str(roundi(_volume * 100.0)) + "%, trading up " + ("on" if _swap else "off") + ")")
	Engine.set_meta("AIActuallyLoots", self)
	get_tree().node_added.connect(_on_node_added)
	if Engine.has_meta("RTVModLib"):
		var lib = Engine.get_meta("RTVModLib")
		if lib._is_ready: _on_lib_ready()
		else: lib.frameworks_ready.connect(_on_lib_ready)
	else:
		push_warning(TAG + "RTVModLib not found, is Metro Mod Loader installed?")

func _on_lib_ready():
	_lib = Engine.get_meta("RTVModLib")
	if _lib.hook("ai-loot", _on_loot) == -1:
		push_warning(TAG + "AI.Loot is already replaced by another mod")
	_lib.hook("ai-changestate-post", _on_change_state)
	_lib.hook("ai-weapondamage-pre", _on_damage_pre)
	_lib.hook("ai-death-post", _on_death)

func _on_node_added(node):
	if node is LootContainer: _containers.append(node)



## ------------------------------------------------------------------------------------------------ settings

## Same file whether or not MCM is installed: MCM shows it as a menu, without MCM it can be edited by hand.
func _load_config():
	DirAccess.make_dir_recursive_absolute(MCM_DIR)
	var path := MCM_DIR.path_join(MCM_FILE)
	var defaults := _config_defaults()
	var config := ConfigFile.new()
	if config.load(path) != OK: config = defaults
	else:
		for section in defaults.get_sections():
			for key in defaults.get_section_keys(section):
				var want: Dictionary = defaults.get_value(section, key)
				var have = config.get_value(section, key, null)
				# Keep the player's value, refresh the rest (names, tooltips, ranges) from this version.
				if have is Dictionary && have.has("value"): want["value"] = have["value"]
				config.set_value(section, key, want)
	config.save(path)
	_apply_config(config)
	var helpers = load(MCM_HELPERS) if ResourceLoader.exists(MCM_HELPERS) else null
	if helpers != null && helpers.has_method("RegisterConfiguration"):
		helpers.RegisterConfiguration(MCM_ID, "AI Actually Loots", MCM_DIR,
			"AI loot houses and bodies when calm. Kill them and you'll find the loot on the body.", {MCM_FILE: _apply_config})

func _config_defaults() -> ConfigFile:
	var c := ConfigFile.new()
	c.set_value("Int", "loot_volume", {"name": "Loot sound volume (%)", "default": 50, "value": 50, "minRange": 0, "maxRange": 100,
		"tooltip": "How loud AI are when they open containers and pick items up. 100 = the game's own volume, 0 = silent."})
	c.set_value("Bool", "trade_up", {"name": "Full AI trade up", "default": true, "value": true,
		"tooltip": "When an AI's inventory is full, it swaps its cheapest item for a clearly more valuable one, leaving the cheap one in the container (or on the floor if it doesn't fit)."})
	return c

func _apply_config(config: ConfigFile):
	var v = config.get_value("Int", "loot_volume", {})
	if v is Dictionary && v.has("value"): _volume = clamp(float(v["value"]) / 100.0, 0.0, 1.0)
	var s = config.get_value("Bool", "trade_up", {})
	if s is Dictionary && s.has("value"): _swap = bool(s["value"])



## ------------------------------------------------------------------------------------------------ deciding

func _physics_process(_delta):
	# Map transitions free the old map's AI, containers and bodies: do nothing until the new map is up.
	if get_tree().current_scene == null || _game_data().transition: return
	var now := _now()
	if now - _botsT > 1.0:
		_botsT = now
		_bots = _live_ai()
	if _bots.is_empty(): return
	for i in min(BOTS_PER_FRAME, _bots.size()):
		_tickIndex = (_tickIndex + 1) % _bots.size()
		var ai = _bots[_tickIndex]
		if is_instance_valid(ai) && !ai.dead && ai.active && ai.is_inside_tree(): _tick(ai, now)

func _tick(ai, now: float):
	if ai.has_meta("aal_loot"):
		if now - float(ai.get_meta("aal_loot")["t"]) > TASK_TIMEOUT: _end_task(ai)
		return
	if now < float(ai.get_meta("aal_next", 0.0)): return
	ai.set_meta("aal_next", now + randf_range(CHECK_INTERVAL.x, CHECK_INTERVAL.y))


	# Nomads never loot (houses, bodies or their own kills).
	if ai.variant.faction == AIData.Faction.Nomad: return
	if !_calm(ai) || ai.reload || ai.container == null: return
	# Inventory full (item limit, or not even a 1x1 item fits): only go on looting to trade up.
	if !_swap && _full(ai): return
	var states = ai.State
	var state: int = ai.currentState
	var hider: bool = state == states.Ambush
	if !(state == states.Wander || state == states.Guard || state == states.Patrol || state == states.Idle || hider): return
	var searching: bool = now < float(ai.get_meta("aal_search_until", 0.0))
	var will: float = WILL.get(ai.variant.faction, 0.2)
	if hider: will = max(will, HIDER_WILL)
	if ai.has_meta("aal_kill") || searching: will = 1.0
	if randf() > will: return


	var reach: float = LOOT_RANGE
	if hider || _home(ai) != null: reach = HOUSE_RANGE
	if searching: reach = SEARCH_ON
	var target = _pick_target(ai, now, reach)
	if target == null: return
	var point = _approach(ai, target)
	if point == null:
		_visited(ai)[target.get_instance_id()] = now
		return
	if hider && is_instance_valid(ai.currentPoint): ai.set_meta("aal_home", ai.currentPoint)
	_start(ai, target, now, point)

## The AI's own kill first, then the nearest fresh body, then the nearest unchecked container. Containers are checked
## whether or not they hold anything (the AI can't know until it looks); checked ones are remembered.
func _pick_target(ai, now: float, reach: float):
	var origin: Vector3 = ai.global_position
	if ai.has_meta("aal_kill"):
		var kill = ai.get_meta("aal_kill")
		ai.remove_meta("aal_kill")
		if is_instance_valid(kill) && kill.is_inside_tree() && kill.global_position.distance_to(origin) < CORPSE_RANGE: return kill


	var best = null
	var bestDist := min(reach, CORPSE_RANGE)
	for entry in _corpses:
		var c = entry["c"]
		if !is_instance_valid(c) || !c.is_inside_tree() || now - float(entry["t"]) > CORPSE_FRESH || _reserved(c, ai, now): continue
		if now - float(_visited(ai).get(c.get_instance_id(), -INF)) < VISIT_FORGET: continue
		# Bandits strip anyone; everyone else only loots enemies.
		if entry["faction"] == ai.variant.faction && ai.variant.faction != AIData.Faction.Bandit: continue
		var d: float = c.global_position.distance_to(origin)
		if d < bestDist:
			best = c
			bestDist = d
	if best != null: return best


	var visited := _visited(ai)
	bestDist = reach
	for c in _containers:
		if !_is_map_container(c) || _reserved(c, ai, now): continue
		if now - float(visited.get(c.get_instance_id(), -INF)) < VISIT_FORGET: continue
		var d: float = c.global_position.distance_to(origin)
		if d < bestDist:
			best = c
			bestDist = d
	return best



## ------------------------------------------------------------------------------------------------ looting

## Walk to the target in Wander with the game's own looting flags set; vanilla Wander() switches to Loot on arrival.
func _start(ai, target, now: float, point: Vector3):
	target.set_meta("aal_reserved", [ai.get_instance_id(), now])
	if ai.currentState != ai.State.Wander:
		ai.set_meta("aal_starting", true)
		ai.ChangeState("Wander")
		ai.remove_meta("aal_starting")
		# No wander points on this map: walk anyway.
		if ai.currentState != ai.State.Wander:
			ai.currentState = ai.State.Wander
			ai.ResetAnimator()
			ai.animator["parameters/conditions/Wander"] = true
			ai.speed = 1.0
			ai.agent.target_desired_distance = 1.0
	ai.set_meta("aal_loot", {"target": target, "left": randi_range(ITEMS_PER_VISIT.x, ITEMS_PER_VISIT.y), "t": now})
	_walk_to(ai, target, point)

func _walk_to(ai, target, point = null):
	ai.looting = true
	ai.lootTarget = target
	ai.currentPoint = target
	ai.MoveToPoint(point if point != null else target.global_position)

## Where to stand to loot `c`: a walkable spot about APPROACH_DIST from it, on its side, with a clear line from chest
## height to it (the nearest navmesh point can be in the next room, behind the wall). Tries the side facing the AI
## first, then the others. null = no such spot (treated as unreachable).
func _approach(ai, c):
	var base: Vector3 = c.global_position
	var center: Vector3 = base + Vector3.UP * 0.5
	var toward: Vector3 = ai.global_position - base
	toward.y = 0.0
	toward = toward.normalized() if toward.length() > 0.01 else Vector3.FORWARD
	var world = ai.get_world_3d() if ai.is_inside_tree() else null
	if world == null: return null
	var space = world.direct_space_state
	for angle in [0.0, 90.0, -90.0, 180.0]:
		var want: Vector3 = base + toward.rotated(Vector3.UP, deg_to_rad(angle)) * APPROACH_DIST
		var spot: Vector3 = NavigationServer3D.map_get_closest_point(ai.navmesh, want)
		if Vector2(spot.x - want.x, spot.z - want.z).length() > 0.7 || abs(spot.y - base.y) > 1.5: continue
		var query := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 1.2, center, ai.sensor.obstruction)
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty() || _part_of(hit["collider"], c): return spot
	return null

## The ray hit the container itself (or the object it sits in), not something next to it like a wall.
func _part_of(collider, c) -> bool:
	if !(collider is Node): return false
	return collider == c || c.is_ancestor_of(collider) || collider.is_ancestor_of(c)


## Replaces vanilla Loot(): same animation, sounds and item transfer, but it stops if the AI left the Loot state
## (vanilla always ended with ChangeState("Wander"), pulling AI out of fights). Also ends the walk home of a hider.
func _on_loot():
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()
	if ai.has_meta("aal_homerun"):
		ai.remove_meta("aal_homerun")
		ai.looting = false
		ai.currentPoint = ai.get_meta("aal_home")
		ai.ChangeState("Ambush")
		return
	_do_loot(ai)

func _do_loot(ai):
	ai.animator["parameters/Wander/P_Loot/request"] = AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	ai.animator["parameters/Wander/R_Loot/request"] = AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	await get_tree().create_timer(0.5, false).timeout
	if !_still_looting(ai): return


	# Open once, then grab up to the visit's item count one after another (or find nothing and move on).
	var target = ai.lootTarget
	var taken := 0
	if is_instance_valid(target) && target is LootContainer:
		_play(ai, target.audioEvent)
		var wanted: int = int(ai.get_meta("aal_loot")["left"]) if ai.has_meta("aal_loot") else 1
		for i in wanted:
			await get_tree().create_timer(GRAB_TIME, false).timeout
			if !_still_looting(ai) || !_has_loot(target): break
			var item = _take_fitting(ai, target) if ai.container.loot.size() < CARRY_LIMIT else null
			if item == null && _swap: item = _trade_up(ai, target)
			if item == null: break
			ai.container.loot.append(item)
			_play(ai, ai.audioLibrary.pickup)
			taken += 1
			print(TAG + ai.name + " looted " + str(item.itemData.name) + (" from a body" if _is_corpse(target) else ""))
	await get_tree().create_timer(0.6 if taken == 0 else 0.8, false).timeout
	if !_still_looting(ai): return
	if taken == 0: print(TAG + ai.name + " found nothing in " + str(target.name if is_instance_valid(target) else "?"))
	ai.looting = false
	ai.ChangeState("Wander")

func _still_looting(ai) -> bool:
	if !is_instance_valid(ai) || ai.dead: return false
	if ai.currentState != ai.State.Loot:
		ai.looting = false
		return false
	return true

## After each item vanilla goes back to Wander: loot again, walk home (hiders), or finish. Any other state ends the
## visit; a hider that reacts to something while out goes back into ambush instead (unless it already sees the enemy).
func _on_change_state(state):
	var ai = _lib._caller
	if !_affects(ai) || ai.has_meta("aal_starting"): return
	if ai.has_meta("aal_homerun") && state != "Wander" && state != "Loot":
		ai.remove_meta("aal_homerun")
		ai.looting = false
		if state != "Ambush" && !ai.sensor.PVisible: _ambush(ai)
		return
	if !ai.has_meta("aal_loot"): return


	if state == "Wander":
		_end_task(ai)
		if _search_on(ai): return
		if _home(ai) != null: _go_home(ai)
	elif state != "Loot":
		_end_task(ai)
		if _home(ai) != null && state != "Ambush" && !ai.sensor.PVisible: _ambush(ai)

## More unchecked containers close by (same room/house): keep searching them before moving on.
## Runs right after vanilla's ChangeState("Wander") picked a random waypoint, before the AI turns toward it: walking
## straight on to the nearest unchecked container avoids the turn-to-leave-then-turn-back.
func _search_on(ai) -> bool:
	var now := _now()
	var visited := _visited(ai)
	var best = null
	var bestDist := SEARCH_ON
	for c in _containers:
		if !_is_map_container(c) || _reserved(c, ai, now): continue
		if now - float(visited.get(c.get_instance_id(), -INF)) < VISIT_FORGET: continue
		var d: float = c.global_position.distance_to(ai.global_position)
		if d < bestDist:
			best = c
			bestDist = d
	if best == null: return false
	var point = _approach(ai, best)
	if point == null:
		visited[best.get_instance_id()] = now
		return false
	ai.set_meta("aal_search_until", now + SEARCH_ON_TIME)
	_start(ai, best, now, point)
	return true

func _end_task(ai):
	if !ai.has_meta("aal_loot"): return
	var target = ai.get_meta("aal_loot")["target"]
	ai.remove_meta("aal_loot")
	ai.looting = false
	if is_instance_valid(target):
		target.remove_meta("aal_reserved")
		_visited(ai)[target.get_instance_id()] = _now()

## Back to the hide spot: walk there with the looting flags pointing at it; arrival ends in Ambush (see _on_loot).
func _go_home(ai):
	ai.set_meta("aal_homerun", true)
	_walk_to(ai, ai.get_meta("aal_home"))

## Public: another mod's perception noticed something near a looting hider -> back into ambush.
func ambush(ai):
	_end_task(ai)
	if _home(ai) != null: _ambush(ai)

## Something is coming: hide spot close by -> go back to it, otherwise ambush right here.
func _ambush(ai):
	var home = _home(ai)
	if home != null && ai.global_position.distance_to(home.global_position) < HOME_RANGE:
		ai.ChangeState("Wander")
		_go_home(ai)
		return
	if home != null: ai.currentPoint = home
	if is_instance_valid(ai.currentPoint): ai.ChangeState("Ambush")

func _home(ai):
	var home = ai.get_meta("aal_home") if ai.has_meta("aal_home") else null
	return home if is_instance_valid(home) else null



## ------------------------------------------------------------------------------------------------ bodies

func _on_damage_pre(_hitbox, _damage, _vector, id):
	var ai = _lib._caller
	if _affects(ai) && !ai.dead && is_instance_valid(id): ai.set_meta("aal_attacker", id)

## Register the body; the AI that killed it (if any) will loot it.
func _on_death(_direction, _force):
	var dead = _lib._caller
	if !_affects(dead): return
	var now := _now()
	_end_task(dead)
	for key in ["aal_home", "aal_kill", "aal_visited", "aal_homerun"]: dead.remove_meta(key)
	if dead.container == null: return


	for i in range(_corpses.size() - 1, -1, -1):
		if !is_instance_valid(_corpses[i]["c"]) || now - float(_corpses[i]["t"]) > CORPSE_FRESH: _corpses.remove_at(i)
	_corpses.append({"c": dead.container, "t": now, "faction": dead.variant.faction})
	if dead.has_meta("aal_attacker"):
		var shooter = dead.get_meta("aal_attacker")
		var killer = shooter.owner if is_instance_valid(shooter) else null
		if killer != null && killer != dead && _affects(killer) && !killer.dead: killer.set_meta("aal_kill", dead.container)
	dead.remove_meta("aal_attacker")



## ------------------------------------------------------------------------------------------------ helpers

## Not alerted: vanilla's own flags, plus another mod's awareness value if present.
func _calm(ai) -> bool:
	var sensor = ai.sensor
	if sensor.hot || sensor.PVisible || is_instance_valid(sensor.threatPriority): return false
	return float(sensor.get_meta("bs_aw", 0.0)) < 0.3

func _affects(ai) -> bool:
	return ai != null && "variant" in ai && ai.variant != null && ai.variant.faction != AIData.Faction.Boss

func _live_ai() -> Array:
	var found := []
	for node in get_tree().get_nodes_in_group("AI"):
		var ai = node.owner if node.owner != null else node
		if _affects(ai) && "dead" in ai && !ai.dead && ai.active && ai.is_inside_tree() && !(ai in found): found.append(ai)
	return found

func _has_loot(c) -> bool:
	if !is_instance_valid(c): return false
	return !(c.storage if c.storaged else c.loot).is_empty()

## Like vanilla LootContainer.AILoot() (a random item, removed from the container), but only from items that will fit
## on the AI's body. null = empty, or nothing left in it fits.
func _take_fitting(ai, c):
	var pool: Array = c.storage if c.storaged else c.loot
	var fitting := []
	for i in pool.size():
		if _fits(ai.container, pool[i].itemData.size): fitting.append(i)
	if fitting.is_empty(): return null
	var index: int = fitting.pick_random()
	var item = pool[index]
	pool.remove_at(index)
	return item

## Full: at the item limit, or not even a 1x1 item fits.
func _full(ai) -> bool:
	return ai.container.loot.size() >= CARRY_LIMIT || !_fits(ai.container, Vector2.ONE)

## Trade up: swap the carried item that gains the most for a clearly more valuable one in the container, if the new one
## fits once the old one is out. The old one goes into the container where it fits, otherwise on the floor. Returns
## the taken item (already removed from the container), or null when nothing is worth swapping.
func _trade_up(ai, c):
	var pool: Array = c.storage if c.storaged else c.loot
	var carried: Array = ai.container.loot
	var bestIn := -1
	var bestOut := -1
	var bestGain := 0.0
	for i in pool.size():
		var worthIn := _worth(pool[i])
		for j in carried.size():
			var worthOut := _worth(carried[j])
			if worthIn < max(worthOut * SWAP_RATIO, worthOut + SWAP_MIN) || worthIn - worthOut <= bestGain: continue
			var rest := carried.duplicate()
			rest.remove_at(j)
			if !_fits_in(ai.container.containerSize, rest, pool[i].itemData.size): continue
			bestIn = i
			bestOut = j
			bestGain = worthIn - worthOut
	if bestIn == -1: return null
	var taken = pool[bestIn]
	pool.remove_at(bestIn)
	var left = carried[bestOut]
	carried.remove_at(bestOut)
	# A container the player has opened keeps fixed grid positions: don't guess one, drop instead.
	if !c.storaged && _fits_in(c.containerSize, c.loot, left.itemData.size):
		c.loot.append(left)
		print(TAG + ai.name + " swapped " + str(left.itemData.name) + " for " + str(taken.itemData.name))
	else:
		_drop(ai, left)
		print(TAG + ai.name + " dropped " + str(left.itemData.name) + " for " + str(taken.itemData.name))
	return taken

## What the item is worth, like vanilla Item.Value(): ammo by how full the box is, magazines and weapons plus the rounds
## in them, everything but electronics scaled by condition.
func _worth(slot) -> float:
	var data = slot.itemData
	var value := float(data.value)
	if (data.type == "Ammo" || data.file == "Matches") && data.defaultAmount > 0:
		value *= float(slot.amount) / float(data.defaultAmount)
	var ammo = null
	if data.subtype == "Magazine" && !data.compatible.is_empty(): ammo = data.compatible[0]
	elif data.type == "Weapon": ammo = data.get("ammo")
	if ammo != null && ammo.defaultAmount > 0:
		value += float(ammo.value) / float(ammo.defaultAmount) * (slot.amount + (1 if data.type == "Weapon" && slot.chamber else 0))
	if data.type != "Electronics": value *= slot.condition * 0.01
	return value

## On the floor in front of the AI, as a normal pickup (vanilla Interface.Drop, split into boxes for stacks).
func _drop(ai, slot):
	var scene = get_node("/root/Database").get(slot.itemData.file)
	var map = get_tree().current_scene
	if scene == null || map == null:
		print(TAG + "can't drop " + str(slot.itemData.name) + ": no pickup scene")
		return
	var forward: Vector3 = ai.global_basis.z
	var amounts := [slot.amount]
	var box: int = slot.itemData.defaultAmount
	if slot.itemData.stackable && box > 0 && slot.amount > box:
		amounts = []
		var left: int = slot.amount
		while left > 0:
			amounts.append(min(left, box))
			left -= box
	for amount in amounts:
		var pickup = scene.instantiate()
		map.add_child(pickup)
		pickup.global_position = ai.global_position + Vector3.UP * 1.0 + forward * 0.4
		pickup.rotation_degrees = Vector3(-25, ai.rotation_degrees.y + randf_range(-45, 45), 45)
		var copy := SlotData.new()
		copy.Update(slot)
		copy.amount = amount
		pickup.slotData.Update(copy)
		pickup.Unfreeze()
		pickup.linear_velocity = forward * 1.0

## The game's loot sound at the container, at the configured volume (vanilla AI.PlayLoot / PlayPickup).
func _play(ai, event):
	if _volume <= 0.0 || event == null || !is_instance_valid(ai.lootTarget): return
	var audio = ai.audioInstance3D.instantiate()
	get_tree().get_root().add_child(audio)
	audio.global_position = ai.lootTarget.global_position
	audio.PlayInstance(event, 8, 100)
	audio.volume_db += linear_to_db(_volume)
	audio.panning_strength = 2.0

## Would an item of this size still show up when the player opens this body? Opening a body deletes whatever doesn't
## fit its grid, so this replays vanilla Interface.FillContainerGrid: each loot entry in order goes to the first free
## cell (row by row), rotated if it doesn't fit upright, and is dropped if it doesn't fit either way.
func _fits(body, size: Vector2) -> bool:
	return _fits_in(body.containerSize, body.loot, size)

func _fits_in(containerSize: Vector2, loot: Array, size: Vector2) -> bool:
	var w := int(clamp(containerSize.x, 4, 8))
	var h := int(clamp(containerSize.y, 1, 13))
	var grid := []
	grid.resize(w * h)
	grid.fill(false)
	for slot in loot:
		_place(grid, w, h, slot.itemData.size)
	return _place(grid, w, h, size)

func _place(grid: Array, w: int, h: int, size: Vector2) -> bool:
	for s in [Vector2i(int(size.x), int(size.y)), Vector2i(int(size.y), int(size.x))]:
		for y in h:
			for x in w:
				if grid[y * w + x] || !_free(grid, w, h, x, y, s): continue
				for dy in s.y:
					for dx in s.x: grid[(y + dy) * w + x + dx] = true
				return true
	return false

func _free(grid: Array, w: int, h: int, x: int, y: int, s: Vector2i) -> bool:
	if x + s.x > w || y + s.y > h: return false
	for dy in s.y:
		for dx in s.x:
			if grid[(y + dy) * w + x + dx]: return false
	return true

func _is_corpse(c) -> bool:
	return c.owner != null && "variant" in c.owner

func _is_map_container(c) -> bool:
	return is_instance_valid(c) && c.is_inside_tree() && c.visible && c.process_mode != Node.PROCESS_MODE_DISABLED \
		&& !c.locked && !c.furniture && !_is_corpse(c)

func _reserved(c, ai, now: float) -> bool:
	if !c.has_meta("aal_reserved"): return false
	var r: Array = c.get_meta("aal_reserved")
	return int(r[0]) != ai.get_instance_id() && now - float(r[1]) < RESERVE_TIME

func _visited(ai) -> Dictionary:
	if !ai.has_meta("aal_visited"): ai.set_meta("aal_visited", {})
	return ai.get_meta("aal_visited")

func _game_data():
	return preload("res://Resources/GameData.tres")

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
