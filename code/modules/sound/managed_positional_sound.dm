/// Maps reserved managed positional sound channels to the datum currently owning them.
var/global/list/managed_positional_sound_channels = list()

/// Registers a managed positional sound with the process scheduler, or queues it until the scheduler exists.
/proc/register_managed_positional_sound(datum/managed_positional_sound/managed_sound)
	if (!managed_sound)
		return

	if (global.managed_positional_sound_process)
		global.managed_positional_sound_process.register_sound(managed_sound)
	else
		global.pending_managed_positional_sounds[managed_sound] = TRUE

/// Removes a managed positional sound from both the pending queue and the active process scheduler.
/proc/unregister_managed_positional_sound(datum/managed_positional_sound/managed_sound)
	if (!managed_sound)
		return

	global.pending_managed_positional_sounds -= managed_sound
	global.managed_positional_sound_process?.unregister_sound(managed_sound)

/// Plays a positional sound whose volume and relative position are managed after the initial send.
/// Returns a datum owned by the caller. Hold onto it and call stop(), set_volume(), set_source(), add_emitter(), or qdel() as needed.
/// Non-repeating sounds are automatically disposed by the process after their sound length elapses, if BYOND reports one.
/proc/play_managed_positional_sound(atom/source, soundin, vol, vary = FALSE, extrarange = 0, pitch = 1, ignore_flag = 0, channel = VOLUME_CHANNEL_GAME, flags = 0, update_interval = MANAGED_POSITIONAL_SOUND_DEFAULT_UPDATE_INTERVAL, repeat = FALSE)
	RETURN_TYPE(/datum/managed_positional_sound)
	if(isarea(source))
		CRASH("play_managed_positional_sound(): source is an area [source.name], sound is [soundin]")

	var/datum/managed_positional_sound/managed_sound = new /datum/managed_positional_sound(source, soundin, vol, vary, extrarange, pitch, ignore_flag, channel, flags, update_interval, repeat)
	if (!managed_sound.sound_channel)
		qdel(managed_sound)
		return null

	return managed_sound

/// Reserves a private BYOND sound channel for a managed positional sound datum.
/proc/acquire_managed_positional_sound_channel(datum/managed_positional_sound/managed_sound)
	if (!global.managed_positional_sound_channels)
		global.managed_positional_sound_channels = list()

	for (var/sound_channel = SOUNDCHANNEL_MANAGED_POSITIONAL_LOW to SOUNDCHANNEL_MANAGED_POSITIONAL_HIGH)
		var/channel_key = "[sound_channel]"
		if (global.managed_positional_sound_channels[channel_key])
			continue

		global.managed_positional_sound_channels[channel_key] = managed_sound
		return sound_channel

	return null

/// Releases a channel previously reserved by a managed positional sound datum.
/proc/release_managed_positional_sound_channel(datum/managed_positional_sound/managed_sound)
	if (!managed_sound?.sound_channel || !global.managed_positional_sound_channels)
		return

	var/channel_key = "[managed_sound.sound_channel]"
	if (global.managed_positional_sound_channels[channel_key] == managed_sound)
		global.managed_positional_sound_channels -= channel_key

/// Smoothstep rolloff for managed positional sounds. This is intentionally softer than the legacy playsound() curve.
/proc/get_managed_positional_sound_falloff_multiplier(dist, max_range)
	if (max_range <= 0)
		return 0

	var/scaled_dist = clamp(dist / max_range, 0, 1)
	return 1 - (scaled_dist * scaled_dist * (3 - (2 * scaled_dist)))

/// Managed positional sounds use their whole hard range; the softer rolloff can remain audible until close to the edge.
/proc/get_managed_positional_sound_query_range(vol, max_range)
	if (vol <= TOO_QUIET || max_range <= 0)
		return 0

	return max_range

/// Smoothly fades an emitter's blend influence as it approaches the edge of its audible range.
/proc/get_managed_positional_sound_blend_edge_fade(dist, max_range)
	if (max_range <= 0)
		return 0

	var/edge_width = max(MANAGED_POSITIONAL_SOUND_BLEND_MIN_EDGE_WIDTH, max_range * MANAGED_POSITIONAL_SOUND_BLEND_EDGE_FRACTION)
	var/scaled_edge_dist = clamp((max_range - dist) / edge_width, 0, 1)
	return scaled_edge_dist * scaled_edge_dist * (3 - (2 * scaled_edge_dist))

/// One physical emitter for a managed positional sound token.
/datum/managed_positional_sound_emitter
	/// Sound token that owns this emitter.
	var/datum/managed_positional_sound/managed_sound
	/// Atom this emitter follows.
	var/atom/source

/datum/managed_positional_sound_emitter/New(datum/managed_positional_sound/managed_sound, atom/source)
	. = ..()
	src.managed_sound = managed_sound
	src.source = source
	src.register_source_signals(src.source)

/datum/managed_positional_sound_emitter/disposing()
	src.unregister_source_signals(src.source)
	global.managed_positional_sound_process?.unregister_emitter(src)
	src.managed_sound = null
	src.source = null
	. = ..()

/// Moves this emitter to a new source atom.
/datum/managed_positional_sound_emitter/proc/set_source(atom/source)
	src.unregister_source_signals(src.source)
	src.source = source
	src.register_source_signals(src.source)
	global.managed_positional_sound_process?.update_emitter_source(src)

/// Registers source deletion and movement signals that should force managed sound updates.
/datum/managed_positional_sound_emitter/proc/register_source_signals(atom/source)
	if (!source)
		return

	src.RegisterSignal(source, COMSIG_PARENT_PRE_DISPOSING, PROC_REF(source_disposing))
	if (ismovable(source))
		src.RegisterSignal(source, XSIG_MOVABLE_TURF_CHANGED, PROC_REF(source_moved))

/// Unregisters all source signals owned by this emitter.
/datum/managed_positional_sound_emitter/proc/unregister_source_signals(atom/source)
	if (!source)
		return

	src.UnregisterSignal(source, COMSIG_PARENT_PRE_DISPOSING)
	if (ismovable(source))
		src.UnregisterSignal(source, XSIG_MOVABLE_TURF_CHANGED)

/// Source deletion callback.
/datum/managed_positional_sound_emitter/proc/source_disposing()
	src.managed_sound?.remove_emitter(src)

/// Source movement callback.
/datum/managed_positional_sound_emitter/proc/source_moved()
	src.managed_sound?.emitter_moved(src)

/// Runtime controller for a positional sound token that needs listener/emitter updates after playback starts.
/datum/managed_positional_sound
	/// Convenience reference to the first emitter source.
	var/atom/source
	/// Physical emitters sharing this sound token's channel and timeline.
	var/list/datum/managed_positional_sound_emitter/emitters = list()
	/// Generated source sound used as the file and property template for all client sends.
	var/sound/sound_template
	/// Base stored volume before listener preferences are applied.
	var/volume = 100
	/// Extra distance beyond MAX_SOUND_RANGE.
	var/extrarange = 0
	/// Base pitch/frequency multiplier.
	var/pitch = 1
	/// Client sound ignore flag checked before sending.
	var/ignore_flag = 0
	/// volume channel used for client-side volume preferences.
	var/volume_channel = VOLUME_CHANNEL_GAME
	/// playsound()-style behavior flags, such as SOUND_IGNORE_DEAF or SOUND_DO_LOS.
	var/flags = 0
	/// Whether the sound should loop on the client. One-shot sounds are the default.
	var/repeat = FALSE
	/// Maximum periodic update delay. Movement signals can still force earlier updates.
	var/update_interval = MANAGED_POSITIONAL_SOUND_DEFAULT_UPDATE_INTERVAL
	/// Minimum stored-volume change needed before an update packet is worth sending.
	var/update_volume_threshold = 1
	/// Maximum stored-volume change per second when smoothing existing listeners.
	var/volume_slew_per_second = 30
	/// Maximum positional offset change per second when smoothing existing listeners.
	var/position_slew_per_second = 6
	/// Minimum positional offset change worth sending to BYOND.
	var/position_deadzone = 0.1
	/// Reserved BYOND channel used by this managed sound.
	var/sound_channel = null
	/// Whether this datum is still registered and sending updates.
	var/active = FALSE
	/// world.time when playback conceptually began, used to synchronize late listeners.
	var/start_time = 0
	/// Earliest world.time this sound should receive its next periodic update.
	var/next_update_time = 0
	/// Cached BYOND sound length in seconds. Zero means BYOND did not report one.
	var/sound_duration = 0

	/// Clients that have received this managed sound and need updates or muting.
	var/list/listeners = list()
	/// Last stored, pre-client-preference volume sent for each listener.
	var/list/client_stored_volumes = list()
	/// Last x positional offset sent for each listener.
	var/list/client_sound_x = list()
	/// Last z positional offset sent for each listener.
	var/list/client_sound_z = list()
	/// Last BYOND environment sent for each listener.
	var/list/client_environment = list()
	/// Last echo settings sent for each listener.
	var/list/client_echo = list()
	/// world.time of the last positional update evaluation for each listener.
	var/list/client_last_update_time = list()

/datum/managed_positional_sound/New(atom/source, soundin, vol, vary = FALSE, extrarange = 0, pitch = 1, ignore_flag = 0, channel = VOLUME_CHANNEL_GAME, flags = 0, update_interval = MANAGED_POSITIONAL_SOUND_DEFAULT_UPDATE_INTERVAL, repeat = FALSE)
	. = ..()

	src.sound_template = generate_sound(source, soundin, vol, vary, extrarange, pitch)
	if (!src.sound_template)
		logTheThing(LOG_DEBUG, null, "<b>Sounds:</b> Unable to create managed positional sound: [soundin]")
		return

	src.sound_channel = acquire_managed_positional_sound_channel(src)
	if (!src.sound_channel)
		logTheThing(LOG_DEBUG, null, "<b>Sounds:</b> Unable to reserve a managed positional sound channel for [soundin]")
		return

	src.volume = vol
	src.extrarange = extrarange
	src.pitch = pitch
	src.ignore_flag = ignore_flag
	src.volume_channel = channel
	src.flags = flags
	src.repeat = repeat
	src.update_interval = max(update_interval, MANAGED_POSITIONAL_SOUND_MIN_UPDATE_INTERVAL)
	src.start_time = world.time
	src.next_update_time = world.time + src.update_interval
	src.sound_duration = src.sound_template.len
	src.active = TRUE

	src.sound_template.channel = src.sound_channel
	src.sound_template.repeat = src.repeat
	src.sound_template.wait = FALSE

	src.add_emitter(source, FALSE)

	register_managed_positional_sound(src)

/// Stops playback for all listeners and releases signal registrations and the reserved sound channel.
/datum/managed_positional_sound/disposing()
	src.active = FALSE

	for (var/datum/managed_positional_sound_emitter/emitter as anything in src.emitters?.Copy())
		qdel(emitter)

	for (var/client/C as anything in src.listeners.Copy())
		src.stop_client(C)

	unregister_managed_positional_sound(src)
	release_managed_positional_sound_channel(src)

	src.source = null
	src.emitters = null
	src.sound_template = null
	src.listeners = null
	src.client_stored_volumes = null
	src.client_sound_x = null
	src.client_sound_z = null
	src.client_environment = null
	src.client_echo = null
	src.client_last_update_time = null

	. = ..()

/// Public stop helper for owners that hold the managed sound datum.
/datum/managed_positional_sound/proc/stop()
	qdel(src)

/// Sets the base volume and schedules an immediate managed update.
/datum/managed_positional_sound/proc/set_volume(vol)
	src.volume = vol
	src.mark_dirty()

/// Moves this managed sound to a new source and immediately recalculates listeners.
/datum/managed_positional_sound/proc/set_source(atom/source)
	src.clear_emitters()
	src.add_emitter(source)

/// Adds a physical emitter to this managed sound.
/datum/managed_positional_sound/proc/add_emitter(atom/source, register = TRUE)
	RETURN_TYPE(/datum/managed_positional_sound_emitter)
	if (!source)
		return null

	for (var/datum/managed_positional_sound_emitter/existing_emitter as anything in src.emitters)
		if (existing_emitter.source == source)
			return existing_emitter

	var/datum/managed_positional_sound_emitter/emitter = new(src, source)
	src.emitters ||= list()
	src.emitters[emitter] = TRUE
	if (!src.source)
		src.source = source

	if (register)
		global.managed_positional_sound_process?.register_emitter(emitter)
		src.mark_dirty()

	return emitter

/// Removes an emitter from this managed sound.
/datum/managed_positional_sound/proc/remove_emitter(datum/managed_positional_sound_emitter/emitter)
	if (!emitter || !(emitter in src.emitters))
		return

	src.emitters -= emitter
	if (src.source == emitter.source)
		src.source = null
		for (var/datum/managed_positional_sound_emitter/remaining as anything in src.emitters)
			src.source = remaining.source
			break

	global.managed_positional_sound_process?.unregister_emitter(emitter)
	qdel(emitter)

	if (!length(src.emitters))
		qdel(src)
	else
		src.mark_dirty()

/// Removes every emitter from this managed sound without stopping the token.
/datum/managed_positional_sound/proc/clear_emitters()
	for (var/datum/managed_positional_sound_emitter/emitter as anything in src.emitters?.Copy())
		src.emitters -= emitter
		global.managed_positional_sound_process?.unregister_emitter(emitter)
		qdel(emitter)
	src.source = null

/// Source movement callback from an owned emitter.
/datum/managed_positional_sound/proc/emitter_moved(datum/managed_positional_sound_emitter/emitter)
	global.managed_positional_sound_process?.update_emitter_source(emitter)

/// Sets the periodic update interval while preserving the global minimum cadence.
/datum/managed_positional_sound/proc/set_update_interval(update_interval)
	src.update_interval = max(update_interval, MANAGED_POSITIONAL_SOUND_MIN_UPDATE_INTERVAL)
	src.next_update_time = min(src.next_update_time, world.time + src.update_interval)
	src.mark_dirty()

/// Returns TRUE once a non-repeating sound with a known length has elapsed.
/datum/managed_positional_sound/proc/is_finished()
	return !src.repeat && src.sound_duration && (src.get_elapsed_seconds() >= src.sound_duration)

/// Returns elapsed wall-clock playback time in BYOND sound seconds.
/datum/managed_positional_sound/proc/get_elapsed_seconds()
	return (world.time - src.start_time) / (1 SECOND)

/// Returns the expected BYOND sound offset for the current world time, or null if the sound length is unknown.
/datum/managed_positional_sound/proc/get_sound_offset()
	if (!src.sound_duration)
		return null

	var/elapsed_seconds = src.get_elapsed_seconds()
	if (src.repeat)
		return elapsed_seconds % src.sound_duration
	return min(elapsed_seconds, src.sound_duration)

/// Returns the broad spatial query range needed to find potential listeners for this sound.
/datum/managed_positional_sound/proc/get_query_range()
	return get_managed_positional_sound_query_range(src.volume, MAX_SOUND_RANGE + src.extrarange)

/// Returns an emitter turf on a z-level, used for silent repeat priming.
/datum/managed_positional_sound/proc/get_emitter_turf_on_z(z)
	RETURN_TYPE(/turf)
	for (var/datum/managed_positional_sound_emitter/emitter as anything in src.emitters)
		var/turf/source_turf = get_turf(emitter.source)
		if (source_turf?.z == z)
			return source_turf

	return null

/// Schedules this sound to update on the next process tick, bypassing its normal periodic interval.
/datum/managed_positional_sound/proc/mark_dirty()
	if (!src.active)
		return

	src.next_update_time = min(src.next_update_time, world.time)
	global.managed_positional_sound_process?.mark_sound_dirty(src)

/// Recomputes nearby clients around all emitters, updates audible clients, and mutes listeners that left range.
/datum/managed_positional_sound/proc/update_nearby_clients(force = FALSE)
	if (!src.active || !src.sound_template)
		return

	if (!length(src.emitters))
		src.mute_all(force)
		return
	if (!global.client_hashmap)
		src.mute_all(force)
		return

	var/list/current_clients = list()
	var/list/emitters_by_client = list()
	for (var/datum/managed_positional_sound_emitter/emitter as anything in src.emitters)
		var/turf/source_turf = get_turf(emitter.source)
		if (!source_turf)
			continue

		for (var/client/C as anything in global.client_hashmap.exact_supremum(source_turf, src.get_query_range()))
			emitters_by_client[C] ||= list()
			emitters_by_client[C] += emitter

	for (var/client/C as anything in emitters_by_client)
		var/list/candidate = src.get_blended_candidate_for_client(C, C?.mob, emitters_by_client[C])
		if (!candidate)
			continue

		src.update_client_from_candidate(C, C?.mob, candidate, force)
		current_clients[C] = TRUE

	for (var/client/C as anything in src.listeners.Copy())
		if (!C?.mob)
			src.stop_client(C)
			continue

		if (current_clients[C])
			continue

		src.mute_client(C, force)

/// Helper for callers that need a full emitter-centred update.
/datum/managed_positional_sound/proc/update_all(force = FALSE)
	src.update_nearby_clients(force)

/// Updates every client already tracked by this sound.
/datum/managed_positional_sound/proc/update_current_listeners(force = FALSE)
	for (var/client/C as anything in src.listeners.Copy())
		if (!C?.mob)
			src.stop_client(C)
			continue

		src.update_for_client(C, C.mob, force)

/// Updates this managed sound for one listener candidate, blending all nearby effective emitters.
/datum/managed_positional_sound/proc/update_for_client(client/C, mob/M, force = FALSE)
	if (global.managed_positional_sound_process)
		return global.managed_positional_sound_process.process_sound_for_client(src, C, M, force)

	var/list/candidate = src.get_blended_candidate_for_client(C, M, src.emitters)
	if (!candidate)
		if (C in src.listeners)
			src.mute_client(C, force)
		return FALSE

	src.update_client_from_candidate(C, M, candidate, force)
	return TRUE

/// Returns one virtual listener candidate blended from every audible emitter in the provided set.
/datum/managed_positional_sound/proc/get_blended_candidate_for_client(client/C, mob/M, list/emitters)
	RETURN_TYPE(/list)
	if (!length(emitters))
		return null

	var/list/candidates = list()
	var/list/loudest_candidate = null
	var/loudest_volume = 0
	for (var/datum/managed_positional_sound_emitter/emitter as anything in emitters)
		var/list/candidate = src.get_candidate_for_client(C, M, emitter)
		if (!candidate)
			continue

		candidates += list(candidate)
		if (!loudest_candidate || candidate["stored_volume"] > loudest_volume)
			loudest_candidate = candidate
			loudest_volume = candidate["stored_volume"]

	if (!loudest_candidate)
		return null

	if (length(candidates) == 1)
		return loudest_candidate

	var/turf/Mloc = loudest_candidate["Mloc"]
	var/volume_cap = max(src.volume * MANAGED_POSITIONAL_SOUND_BLEND_VOLUME_CAP_MULT, loudest_volume)
	var/remaining_volume_fraction = 1
	var/weighted_x = 0
	var/weighted_z = 0
	var/total_direction_weight = 0

	for (var/list/candidate as anything in candidates)
		var/stored_volume = candidate["stored_volume"]
		var/normalized_volume = clamp(stored_volume / volume_cap, 0, 1)
		remaining_volume_fraction *= (1 - normalized_volume)

		var/edge_fade = get_managed_positional_sound_blend_edge_fade(candidate["dist"], candidate["max_range"])
		var/direction_weight = stored_volume * stored_volume * edge_fade
		if (direction_weight <= 0)
			continue

		weighted_x += candidate["sound_x"] * direction_weight
		weighted_z += candidate["sound_z"] * direction_weight
		total_direction_weight += direction_weight

	var/combined_volume = volume_cap * (1 - remaining_volume_fraction)
	if (combined_volume < TOO_QUIET)
		return null

	var/sound_x = loudest_candidate["sound_x"]
	var/sound_z = loudest_candidate["sound_z"]
	if (total_direction_weight > 0)
		sound_x = weighted_x / total_direction_weight
		sound_z = weighted_z / total_direction_weight

	return list(
		"emitter" = loudest_candidate["emitter"],
		"source" = loudest_candidate["source"],
		"stored_volume" = combined_volume,
		"Mloc" = Mloc,
		"source_turf" = loudest_candidate["source_turf"],
		"source_location" = loudest_candidate["source_location"],
		"listener_location" = loudest_candidate["listener_location"],
		"spaced_env" = loudest_candidate["spaced_env"],
		"sound_x" = sound_x,
		"sound_z" = sound_z,
	)

/// Returns one debug-only virtual sound field contribution at a turf, ignoring client preferences and mob hearing checks.
/datum/managed_positional_sound/proc/get_debug_blended_field_for_turf(turf/listener_turf, list/emitters)
	RETURN_TYPE(/list)
	if (!listener_turf || !length(emitters))
		return null

	var/list/candidates = list()
	var/list/loudest_candidate = null
	var/loudest_volume = 0
	for (var/datum/managed_positional_sound_emitter/emitter as anything in emitters)
		var/list/candidate = src.get_debug_candidate_for_turf(listener_turf, emitter)
		if (!candidate)
			continue

		candidates += list(candidate)
		if (!loudest_candidate || candidate["stored_volume"] > loudest_volume)
			loudest_candidate = candidate
			loudest_volume = candidate["stored_volume"]

	if (!loudest_candidate)
		return null

	if (length(candidates) == 1)
		loudest_candidate["emitter_count"] = 1
		loudest_candidate["volume_cap"] = max(src.volume * MANAGED_POSITIONAL_SOUND_BLEND_VOLUME_CAP_MULT, loudest_volume)
		return loudest_candidate

	var/volume_cap = max(src.volume * MANAGED_POSITIONAL_SOUND_BLEND_VOLUME_CAP_MULT, loudest_volume)
	var/remaining_volume_fraction = 1
	var/weighted_x = 0
	var/weighted_z = 0
	var/total_direction_weight = 0

	for (var/list/candidate as anything in candidates)
		var/stored_volume = candidate["stored_volume"]
		var/normalized_volume = clamp(stored_volume / volume_cap, 0, 1)
		remaining_volume_fraction *= (1 - normalized_volume)

		var/edge_fade = get_managed_positional_sound_blend_edge_fade(candidate["dist"], candidate["max_range"])
		var/direction_weight = stored_volume * stored_volume * edge_fade
		if (direction_weight <= 0)
			continue

		weighted_x += candidate["sound_x"] * direction_weight
		weighted_z += candidate["sound_z"] * direction_weight
		total_direction_weight += direction_weight

	var/combined_volume = volume_cap * (1 - remaining_volume_fraction)
	if (combined_volume < TOO_QUIET)
		return null

	var/sound_x = loudest_candidate["sound_x"]
	var/sound_z = loudest_candidate["sound_z"]
	if (total_direction_weight > 0)
		sound_x = weighted_x / total_direction_weight
		sound_z = weighted_z / total_direction_weight

	return list(
		"emitter" = loudest_candidate["emitter"],
		"source" = loudest_candidate["source"],
		"stored_volume" = combined_volume,
		"volume_cap" = volume_cap,
		"emitter_count" = length(candidates),
		"source_turf" = loudest_candidate["source_turf"],
		"sound_x" = sound_x,
		"sound_z" = sound_z,
	)

/// Returns the loudest effective emitter candidate for a listener.
/datum/managed_positional_sound/proc/get_best_candidate_for_client(client/C, mob/M)
	RETURN_TYPE(/list)
	var/list/best_candidate = null
	for (var/datum/managed_positional_sound_emitter/emitter as anything in src.emitters)
		var/list/candidate = src.get_candidate_for_client(C, M, emitter)
		if (!candidate)
			continue
		if (!best_candidate || candidate["stored_volume"] > best_candidate["stored_volume"])
			best_candidate = candidate

	return best_candidate

/// Returns this emitter's effective listener candidate data, or null if inaudible.
/datum/managed_positional_sound/proc/get_candidate_for_client(client/C, mob/M, datum/managed_positional_sound_emitter/emitter)
	RETURN_TYPE(/list)
	if (!src.active || !src.sound_template || !C || !M)
		return null

	var/atom/source = emitter?.source
	var/turf/source_turf = get_turf(source)
	var/turf/Mloc = get_turf(M)
	if (!source_turf || !Mloc)
		return null

	var/vol = src.volume
	if (vol < TOO_QUIET)
		return null

	var/ignore_flag = src.ignore_flag
	if (CLIENT_IGNORES_SOUND(C))
		return null

	if (!(src.flags & SOUND_IGNORE_DEAF) && !M.hearing_check(FALSE, TRUE))
		return null

	var/extrarange = src.extrarange
	var/spaced_source = FALSE
	var/atten_temp = attenuate_for_location(source_turf)
	SOURCE_ATTEN(atten_temp)
	if (vol < TOO_QUIET)
		return null

	var/max_range = MAX_SOUND_RANGE + extrarange
	if (max_range <= 0)
		return null

	var/dist = max(GET_MANHATTAN_DIST(Mloc, source_turf), 1)
	if (dist > max_range)
		return null

	var/area/source_location = get_area(source)
	var/source_location_sound_group = null
	if (source_location)
		source_location_sound_group = source_location.sound_group

	var/area/listener_location = Mloc.loc
	if (listener_location)
		if (source_location_sound_group && source_location_sound_group != listener_location.sound_group)
			return null

	var/ourvolume = vol * get_managed_positional_sound_falloff_multiplier(dist, max_range)

	var/spaced_env = FALSE
	atten_temp = attenuate_for_location(Mloc)
	LISTENER_ATTEN(atten_temp)
	if (ourvolume < TOO_QUIET)
		return null

	if (src.flags & SOUND_DO_LOS)
		if (!(M in hearers(MAX_SOUND_RANGE, source)))
			return null

	return list(
		"emitter" = emitter,
		"source" = source,
		"stored_volume" = ourvolume,
		"Mloc" = Mloc,
		"source_turf" = source_turf,
		"source_location" = source_location,
		"listener_location" = listener_location,
		"spaced_env" = spaced_env,
		"dist" = dist,
		"max_range" = max_range,
		"sound_x" = source_turf.x - Mloc.x,
		"sound_z" = source_turf.y - Mloc.y,
	)

/// Returns this emitter's debug field contribution at a turf, or null if it does not contribute there.
/datum/managed_positional_sound/proc/get_debug_candidate_for_turf(turf/listener_turf, datum/managed_positional_sound_emitter/emitter)
	RETURN_TYPE(/list)
	if (!src.active || !src.sound_template || !listener_turf)
		return null

	var/atom/source = emitter?.source
	var/turf/source_turf = get_turf(source)
	if (!source_turf)
		return null

	var/vol = src.volume
	if (vol < TOO_QUIET)
		return null

	var/extrarange = src.extrarange
	var/spaced_source = FALSE
	var/atten_temp = attenuate_for_location(source_turf)
	SOURCE_ATTEN(atten_temp)
	if (vol < TOO_QUIET)
		return null

	var/max_range = MAX_SOUND_RANGE + extrarange
	if (max_range <= 0)
		return null

	var/dist = max(GET_MANHATTAN_DIST(listener_turf, source_turf), 1)
	if (dist > max_range)
		return null

	var/area/source_location = get_area(source)
	var/source_location_sound_group = null
	if (source_location)
		source_location_sound_group = source_location.sound_group

	var/area/listener_location = listener_turf.loc
	if (listener_location)
		if (source_location_sound_group && source_location_sound_group != listener_location.sound_group)
			return null

	var/ourvolume = vol * get_managed_positional_sound_falloff_multiplier(dist, max_range)

	var/spaced_env = FALSE
	atten_temp = attenuate_for_location(listener_turf)
	LISTENER_ATTEN(atten_temp)
	if (ourvolume < TOO_QUIET)
		return null

	return list(
		"emitter" = emitter,
		"source" = source,
		"stored_volume" = ourvolume,
		"source_turf" = source_turf,
		"spaced_env" = spaced_env,
		"dist" = dist,
		"max_range" = max_range,
		"sound_x" = source_turf.x - listener_turf.x,
		"sound_z" = source_turf.y - listener_turf.y,
	)

/// Applies a precomputed listener candidate.
/datum/managed_positional_sound/proc/update_client_from_candidate(client/C, mob/M, list/candidate, force = FALSE)
	if (!candidate)
		return

	src.update_client(C, M, candidate["Mloc"], candidate["source_turf"], candidate["source"], candidate["source_location"], candidate["listener_location"], candidate["stored_volume"], candidate["spaced_env"], force, candidate["sound_x"], candidate["sound_z"])

/// Sends the initial file-bearing packet for a silent listener prime.
/datum/managed_positional_sound/proc/prime_client(client/C, mob/M, turf/Mloc, turf/source_turf)
	if (!src.repeat || !C || !M || !Mloc || !source_turf)
		return

	var/sound/S = src.create_start_sound()
	S.volume = 0
	S.x = source_turf.x - Mloc.x
	S.z = source_turf.y - Mloc.y
	S.y = 0

	var/sound_offset = src.get_sound_offset()
	if (!isnull(sound_offset))
		S.offset = sound_offset

	C << S

	src.add_listener(C, M)
	src.client_stored_volumes[C] = 0
	src.client_sound_x[C] = S.x
	src.client_sound_z[C] = S.z
	src.client_environment[C] = null
	src.client_echo[C] = null
	src.client_last_update_time[C] = world.time
	C.sound_playing[src.sound_channel][1] = 0
	C.sound_playing[src.sound_channel][2] = src.volume_channel

/// Updates or starts this managed sound for one listener.
/datum/managed_positional_sound/proc/update_client(client/C, mob/M, turf/Mloc, turf/source_turf, atom/source_atom, area/source_location, area/listener_location, stored_volume, spaced_env, force = FALSE, sound_x = null, sound_z = null)
	if (!C || !Mloc || !source_turf)
		return

	var/already_playing = (C in src.listeners)
	var/target_stored_volume = stored_volume
	if (already_playing)
		stored_volume = src.smooth_stored_volume(src.client_stored_volumes[C], target_stored_volume)

	var/final_volume = stored_volume * C.getVolume(src.volume_channel) / 100
	if (target_stored_volume * C.getVolume(src.volume_channel) / 100 < TOO_QUIET && !already_playing)
		return

	if (isnull(sound_x))
		sound_x = source_turf.x - Mloc.x
	if (isnull(sound_z))
		sound_z = source_turf.y - Mloc.y
	if (already_playing)
		var/delta_time = src.get_client_update_delta_seconds(C)
		sound_x = src.smooth_sound_offset(src.client_sound_x[C], sound_x, delta_time)
		sound_z = src.smooth_sound_offset(src.client_sound_z[C], sound_z, delta_time)
	var/environment = 0
	var/echo = null

	if (spaced_env && !(src.flags & SOUND_IGNORE_SPACE) && (isturf(source_atom) || ismob(source_atom) || !(M in source_atom)))
		environment = SPACED_ENV
		echo = SPACED_ECHO
	else if (listener_location != source_location)
		echo = ECHO_AFAR
	else
		echo = ECHO_CLOSE

	if (!force && already_playing)
		var/last_volume = src.client_stored_volumes[C]
		if (abs(stored_volume - last_volume) < src.update_volume_threshold \
			&& src.client_sound_x[C] == sound_x \
			&& src.client_sound_z[C] == sound_z \
			&& src.client_environment[C] == environment \
			&& src.client_echo[C] == echo)
			return

	src.add_listener(C, M)
	src.client_stored_volumes[C] = stored_volume
	src.client_sound_x[C] = sound_x
	src.client_sound_z[C] = sound_z
	src.client_environment[C] = environment
	src.client_echo[C] = echo
	src.client_last_update_time[C] = world.time

	C.sound_playing[src.sound_channel][1] = stored_volume
	C.sound_playing[src.sound_channel][2] = src.volume_channel

	var/sound/S
	if (already_playing)
		S = sound(null, wait = FALSE, channel = src.sound_channel)
		S.status = SOUND_UPDATE
		S.repeat = src.repeat
	else
		S = src.create_start_sound()
	S.volume = final_volume
	S.environment = environment
	S.echo = echo
	S.x = sound_x
	S.z = sound_z
	S.y = 0

	var/sound_offset = src.get_sound_offset()
	if (!isnull(sound_offset))
		S.offset = sound_offset

	var/orig_freq
	if (!already_playing)
		orig_freq = S.frequency
		S.frequency *= (HAS_ATOM_PROPERTY(M, PROP_MOB_HEARD_PITCH) ? GET_ATOM_PROPERTY(M, PROP_MOB_HEARD_PITCH) : 1)

	C << S
	if (!already_playing)
		src.send_update_sound(C, final_volume, environment, echo, sound_x, sound_z, sound_offset)

	if (!already_playing)
		S.frequency = orig_freq
		S.offset = 0

/// Builds the initial file-bearing sound packet for a listener.
/datum/managed_positional_sound/proc/create_start_sound()
	var/sound/S = sound(src.sound_template.file, wait = FALSE, channel = src.sound_channel)
	S.repeat = src.repeat
	S.status = 0
	S.falloff = src.sound_template.falloff
	S.priority = src.sound_template.priority
	S.frequency = src.sound_template.frequency
	return S

/// Sends a fileless SOUND_UPDATE packet for an already-started managed sound channel.
/datum/managed_positional_sound/proc/send_update_sound(client/C, volume, environment, echo, sound_x, sound_z, sound_offset = null)
	var/sound/S = sound(null, wait = FALSE, channel = src.sound_channel)
	S.status = SOUND_UPDATE
	S.repeat = src.repeat
	S.volume = volume
	S.environment = environment
	S.echo = echo
	S.x = sound_x
	S.z = sound_z
	S.y = 0
	if (!isnull(sound_offset))
		S.offset = sound_offset
	C << S

/// Mutes every current listener, optionally forcing volume directly to zero.
/datum/managed_positional_sound/proc/mute_all(force = FALSE)
	for (var/client/C as anything in src.listeners.Copy())
		src.mute_client(C, force)

/// Smoothly mutes a listener or immediately stops its audible volume when forced.
/datum/managed_positional_sound/proc/mute_client(client/C, force = FALSE)
	if (!C)
		return

	if (!force && src.client_stored_volumes[C] == 0)
		return

	var/stored_volume = force ? 0 : src.smooth_stored_volume(src.client_stored_volumes[C], 0)
	if (stored_volume < TOO_QUIET)
		stored_volume = 0

	src.client_stored_volumes[C] = stored_volume
	if (!stored_volume)
		src.client_sound_x[C] = null
		src.client_sound_z[C] = null
		src.client_environment[C] = null
		src.client_echo[C] = null
		src.client_last_update_time[C] = world.time

	C.sound_playing[src.sound_channel][1] = stored_volume
	C.sound_playing[src.sound_channel][2] = src.volume_channel

	var/sound/S = sound(null, wait = FALSE, channel = src.sound_channel)
	S.status = SOUND_UPDATE
	S.repeat = src.repeat
	S.volume = stored_volume * C.getVolume(src.volume_channel) / 100
	var/sound_offset = src.get_sound_offset()
	if (!isnull(sound_offset))
		S.offset = sound_offset
	C << S
	src.client_last_update_time[C] = world.time

/// Tracks a client as an active listener and attaches movement/logout signals to its current mob.
/datum/managed_positional_sound/proc/add_listener(client/C, mob/M)
	if (!C || !M)
		return

	src.listeners[C] = TRUE
	global.managed_positional_sound_process?.register_client_sound(C, src)

/// Steps stored volume toward the target to avoid abrupt managed update changes.
/datum/managed_positional_sound/proc/smooth_stored_volume(current_volume, target_volume)
	if (isnull(current_volume))
		return target_volume

	var/max_delta = max(src.volume_slew_per_second * (src.update_interval / 1 SECOND), src.update_volume_threshold)
	return current_volume + clamp(target_volume - current_volume, -max_delta, max_delta)

/// Returns elapsed seconds since the last positional update evaluation and advances the slew clock.
/datum/managed_positional_sound/proc/get_client_update_delta_seconds(client/C)
	var/last_update_time = src.client_last_update_time[C]
	src.client_last_update_time[C] = world.time
	if (isnull(last_update_time))
		return src.update_interval / (1 SECOND)

	return max((world.time - last_update_time) / (1 SECOND), MANAGED_POSITIONAL_SOUND_PROCESS_INTERVAL / (1 SECOND))

/// Steps a positional sound offset toward its target to avoid abrupt stereo pan changes.
/datum/managed_positional_sound/proc/smooth_sound_offset(current_offset, target_offset, delta_time)
	if (isnull(current_offset))
		return target_offset

	if (abs(target_offset - current_offset) <= src.position_deadzone)
		return current_offset

	var/max_delta = max(src.position_slew_per_second * delta_time, src.position_deadzone)
	return current_offset + clamp(target_offset - current_offset, -max_delta, max_delta)

/// Fully stops this sound for a client and clears all per-listener tracking state.
/datum/managed_positional_sound/proc/stop_client(client/C)
	if (!C)
		return

	C.sound_playing[src.sound_channel][1] = 0
	C.sound_playing[src.sound_channel][2] = src.volume_channel

	var/sound/stopsound = sound(null, wait = 0, channel = src.sound_channel)
	C << stopsound

	src.listeners -= C
	global.managed_positional_sound_process?.unregister_client_sound(C, src)
	src.client_stored_volumes -= C
	src.client_sound_x -= C
	src.client_sound_z -= C
	src.client_environment -= C
	src.client_echo -= C
	src.client_last_update_time -= C
