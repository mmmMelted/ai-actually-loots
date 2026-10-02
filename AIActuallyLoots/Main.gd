extends Node
## AI Actually Loots: makes Road to Vostok's AI loot, as the game intends.
##
## Why: the game has AI looting code (Wander -> GetLootPoint -> Loot -> LootContainer.AILoot), but it never finds
## anything: the AI's loot detection area has no collision mask and containers have no area to detect, so
## GetLootPoint() always returns false. This mod finds targets itself and hands them to the game's own looting.
##
## - Calm AI (not alerted or fighting) walk to nearby containers and take 1-3 items into their own inventory (you find
##   them on the body). Bandits loot often; Guards and Military only very rarely (about once per 5 / 10 calm minutes);
##   Nomads never loot.
## - Hiders (AI waiting in ambush in houses) loot the house instead of standing still, return to their hide spot, and
##   drop everything to get back into ambush the moment something approaches.
## - After a kill, the killer loots the body once things calm down; other calm AI scavenge fresh bodies nearby
##   (bandits loot anyone, others only enemies).
## - Fixes vanilla Loot() sending an AI back to wandering when its loot animation ends, even mid-fight.
## Bosses are left alone. Works on its own or alongside other AI mods.


const VERSION := "1.1.5"
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


var _lib = null
var _containers := []
var _corpses := []
var _bots := []
var _botsT := -100.0
var _tickIndex := 0



func _ready():
	print(TAG + "v" + VERSION + " loaded")
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



## ------------------------------------------------------------------------------------------------ deciding

func _physics_process(_delta):
	var now := _now()
	if now - _botsT > 1.0:
		_botsT = now
		_bots = _live_ai()
	if _bots.is_empty(): return
	for i in min(BOTS_PER_FRAME, _bots.size()):
		_tickIndex = (_tickIndex + 1) % _bots.size()
		var ai = _bots[_tickIndex]
		if is_instance_valid(ai) && !ai.dead && ai.active: _tick(ai, now)

func _tick(ai, now: float):
	if ai.has_meta("aal_loot"):
		if now - float(ai.get_meta("aal_loot")["t"]) > TASK_TIMEOUT: _end_task(ai)
		return
	if now < float(ai.get_meta("aal_next", 0.0)): return
	ai.set_meta("aal_next", now + randf_range(CHECK_INTERVAL.x, CHECK_INTERVAL.y))


	# Nomads never loot (houses, bodies or their own kills).
	if ai.variant.faction == AIData.Faction.Nomad: return
	if !_calm(ai) || ai.reload || ai.container == null || ai.container.loot.size() >= CARRY_LIMIT: return
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
		if is_instance_valid(kill) && kill.global_position.distance_to(origin) < CORPSE_RANGE: return kill


	var best = null
	var bestDist := min(reach, CORPSE_RANGE)
	for entry in _corpses:
		var c = entry["c"]
		if !is_instance_valid(c) || now - float(entry["t"]) > CORPSE_FRESH || _reserved(c, ai, now): continue
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
	var space = ai.get_world_3d().direct_space_state
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
		ai.PlayLoot()
		var wanted: int = int(ai.get_meta("aal_loot")["left"]) if ai.has_meta("aal_loot") else 1
		for i in wanted:
			await get_tree().create_timer(GRAB_TIME, false).timeout
			if !_still_looting(ai) || ai.container.loot.size() >= CARRY_LIMIT || !_has_loot(target): break
			var item = target.AILoot()
			if item == null: break
			ai.container.loot.append(item)
			ai.PlayPickup()
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
		if _affects(ai) && "dead" in ai && !ai.dead && ai.active && !(ai in found): found.append(ai)
	return found

func _has_loot(c) -> bool:
	if !is_instance_valid(c): return false
	return !(c.storage if c.storaged else c.loot).is_empty()

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

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
