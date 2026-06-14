TYPEINFO(/obj/item/device/microphone)
	start_listen_effects = list(LISTEN_EFFECT_MICROPHONE)
	start_listen_inputs = list(LISTEN_INPUT_OUTLOUD_RANGE_1)
	start_listen_languages = list(LANGUAGE_ALL)

/obj/item/device/microphone
	name = "microphone"
	icon = 'icons/obj/items/device.dmi'
	icon_state = "mic"
	item_state = "mic"
	HELP_MESSAGE_OVERRIDE("Turn on or off by <b>using in-hand</b>.<br>Only picks up sound in your <b>active hand</b>.")

	var/max_font = 8
	var/font_amp = 4
	var/on = 0

	get_desc()
		..()
		. += "It's currently [src.on ? "on" : "off"]."

	attack_self(mob/user as mob)
		src.on = !(src.on)
		tooltip_rebuild = TRUE
		user.show_text("You switch [src] [src.on ? "on" : "off"].")
		if (src.on && prob(5))
			if (locate(/obj/machinery/loudspeaker) in range(2, user))
				for_by_tcl(S, /obj/machinery/loudspeaker)
					if(!IN_RANGE(S, user, 7)) continue
					S.visible_message(SPAN_ALERT("[S] lets out a horrible [pick("shriek", "squeal", "noise", "squawk", "screech", "whine", "squeak")]!"))
					playsound(S.loc, 'sound/items/mic_feedback.ogg', 30, 1)

	attack_hand(mob/user)
		if (user.find_in_hand(src) && src.on)
			playsound(user, 'sound/misc/miccheck.ogg', 30, TRUE)
			user.visible_message(SPAN_EMOTE("[user] taps [src] with [his_or_her(user)] hand."))
		else
			return ..()


TYPEINFO(/obj/mic_stand)
	analyser_flags = parent_type::analyser_flags | ANALYSER_ELECTRONIC
	mats = 10

/obj/mic_stand
	name = "microphone stand"
	icon = 'icons/obj/items/device.dmi'
	icon_state = "micstand"
	layer = FLY_LAYER
	var/obj/item/device/microphone/myMic = null

	New()
		SPAWN(1 DECI SECOND)
			if (!myMic)
				myMic = new(src)
		return ..()

	attack_hand(mob/user)
		if (!myMic)
			return ..()
		user.put_in_hand_or_drop(myMic)
		myMic = null
		src.UpdateIcon()
		return ..()

	attackby(obj/item/W, mob/user)
		if (istype(W, /obj/item/device/microphone))
			if (myMic)
				user.show_text("There's already a microphone on [src]!", "red")
				return
			user.show_text("You place [W] on [src].", "blue")
			myMic = W
			user.u_equip(W)
			W.set_loc(src)
			src.UpdateIcon()
		else
			return ..()

	update_icon()
		if (myMic)
			switch (myMic.icon_state)
				if ("radio_mic1")
					src.icon_state = "micstand-b"
				if ("radio_mic2")
					src.icon_state = "micstand-r"
				else
					src.icon_state = "micstand"
		else
			src.icon_state = "micstand-empty"

TYPEINFO(/obj/machinery/loudspeaker)
	mats = 15

/obj/machinery/loudspeaker
	name = "loudspeaker"
	icon = 'icons/obj/items/device.dmi'
	icon_state = "loudspeaker"
	anchored = ANCHORED
	density = 1
	object_flags = NO_BLOCK_TABLE
	deconstruct_flags = DECON_SCREWDRIVER | DECON_WRENCH | DECON_MULTITOOL

	HELP_MESSAGE_OVERRIDE("Speech into nearby microphones will be played over this loudspeaker.")

/obj/machinery/loudspeaker/New()
	. = ..()
	START_TRACKING
	src.AddComponent(/datum/component/obj_projectile_damage)
	src.UnsubscribeProcess()

/obj/machinery/loudspeaker/disposing()
	. = ..()
	STOP_TRACKING

/obj/machinery/loudspeaker/set_broken()
	. = ..()
	if(.) return
	src.SubscribeToProcess()
	AddComponent(/datum/component/equipment_fault/elecflash, tool_flags = TOOL_SCREWING | TOOL_WIRING | TOOL_SNIPPING)
	src.visible_message(SPAN_ALERT("[src] sparks and pops, shorting out!"))
	playsound(src, 'sound/effects/screech_tone.ogg', 70, 2, pitch=0.5)
	for (var/mob/living/M in hearers(5, src))
		M.do_disorient(50, target_type = DISORIENT_EAR, remove_stamina_below_zero = TRUE)

/obj/machinery/loudspeaker/ex_act(severity)
	. = ..()
	if(QDELETED(src))
		return
	switch(severity)
		if (2)
			changeHealth(rand(-25, -35))
		if (3)
			changeHealth(rand(-5, -15))

/obj/machinery/loudspeaker/process(mult)
	. = ..()
	if (!(src.status & BROKEN))
		src.UnsubscribeProcess()

/obj/machinery/loudspeaker/changeHealth(change)
	. = ..()
	if(prob(100*(src._health/src._max_health)))
		src.set_broken()

TYPEINFO(/obj/machinery/loudspeaker/positional_multi_emitter_demo)
	admin_procs = list(
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_play,
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_stop,
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_pause_or_resume,
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_set_song,
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_set_volume,
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_set_pitch,
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_refresh_emitters,
		/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_toggle_hand_controls,
	)

/// Demo loudspeaker that plays one managed positional sound through nearby passive demo speakers.
/obj/machinery/loudspeaker/positional_multi_emitter_demo
	name = "positional multi-emitter demo speaker"
	desc = "A loudspeaker playing a synchronized positional test sound from nearby demo emitters."

	/// Sound file used by this demo speaker.
	var/loop_sound = 'sound/ambience/station/Machinery_Computers1.ogg'
	/// Base volume before distance falloff and listener volume preferences.
	var/loop_volume = 60
	/// Pitch/frequency multiplier used by the demo loop.
	var/loop_pitch = 1
	/// Extra range added to MAX_SOUND_RANGE for this demo.
	var/loop_extrarange = 0
	/// Volume channel used by the demo loop.
	var/loop_volume_channel = VOLUME_CHANNEL_INSTRUMENTS
	/// Managed positional sound behavior flags.
	var/loop_flags = 0
	/// Maximum interval between managed positional sound updates.
	var/loop_update_interval = MANAGED_POSITIONAL_SOUND_DEFAULT_UPDATE_INTERVAL
	/// Whether the demo starts playing when spawned.
	var/starts_on = TRUE
	/// If FALSE, hand controls do nothing. Admin-interact controls still work.
	var/hand_controls_enabled = TRUE
	/// Maximum distance to search for passive demo emitters when starting.
	var/emitter_search_range = 15
	/// Active managed positional sound datum owned by this speaker.
	var/datum/managed_positional_sound/managed_sound_loop = null

/obj/machinery/loudspeaker/positional_multi_emitter_demo/New()
	. = ..()
	if (src.starts_on)
		SPAWN(1 DECI SECOND)
			if (!QDELETED(src))
				src.start_sound_loop()

/obj/machinery/loudspeaker/positional_multi_emitter_demo/disposing()
	src.stop_sound_loop()
	. = ..()

/obj/machinery/loudspeaker/positional_multi_emitter_demo/attack_hand(mob/user)
	if (!src.can_use_demo_controls(user))
		user?.show_text("[src]'s controls are locked.", "red")
		return

	if (!src.managed_sound_loop)
		if (tgui_alert(user, "What would you like to do with [src]?", "Speaker Controls", list("Play", "Cancel")) == "Play")
			if (src.start_sound_loop())
				user?.show_text("Started [src].")
			else
				user?.show_text("[src] doesn't respond. Check that a managed positional sound channel is available.", "red")
		return

	var/pause_choice = src.managed_sound_loop.paused ? "Resume" : "Pause"
	switch (tgui_alert(user, "What would you like to do with [src]?", "Speaker Controls", list(pause_choice, "Stop", "Cancel")))
		if ("Pause", "Resume")
			var/paused = !src.managed_sound_loop.paused
			src.managed_sound_loop.set_paused(paused)
			user?.show_text("[paused ? "Paused" : "Resumed"] [src].")
		if ("Stop")
			src.stop_sound_loop()
			user?.show_text("Stopped [src].")
	return

/obj/machinery/loudspeaker/positional_multi_emitter_demo/set_broken()
	. = ..()
	if (!.)
		src.stop_sound_loop()

/// Starts this demo speaker's looping managed positional sound and attaches passive demo speakers as emitters.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/start_sound_loop()
	if (src.managed_sound_loop || (src.status & BROKEN) || !src.loop_sound)
		return FALSE

	src.managed_sound_loop = play_managed_positional_sound(src, src.loop_sound, src.loop_volume, FALSE, src.loop_extrarange, src.loop_pitch, 0, src.loop_volume_channel, src.loop_flags, src.loop_update_interval, TRUE)
	if (!src.managed_sound_loop)
		return FALSE

	src.refresh_emitters()
	return TRUE

/// Rebuilds this demo sound's passive emitter list.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/refresh_emitters()
	if (!src.managed_sound_loop)
		return 0

	var/emitters_added = 0
	var/turf/source_turf = get_turf(src)
	src.managed_sound_loop.clear_emitters()
	src.managed_sound_loop.add_emitter(src)
	for_by_tcl(emitter, /obj/machinery/loudspeaker/positional_multi_emitter_demo/passive)
		var/turf/emitter_turf = get_turf(emitter)
		if (!source_turf || !emitter_turf || emitter_turf.z != source_turf.z || !IN_RANGE(src, emitter, src.emitter_search_range))
			continue
		if (emitter.status & BROKEN)
			continue
		src.managed_sound_loop.add_emitter(emitter)
		emitters_added++

	return emitters_added

/// Stops this demo speaker's active managed positional sound.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/stop_sound_loop()
	if (!src.managed_sound_loop)
		return FALSE

	src.managed_sound_loop.stop()
	src.managed_sound_loop = null
	return TRUE

/// Returns TRUE if a user may use the demo's normal hand controls.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/can_use_demo_controls(mob/user)
	return src.hand_controls_enabled

/// Admin-interact: start playback.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_play()
	set name = "Managed Positional Demo: Play"
	USR_ADMIN_ONLY
	var/mob/user = usr
	if (src.start_sound_loop())
		user?.show_text("Started [src].")
	else
		user?.show_text("[src] is already playing or could not start.", "red")

/// Admin-interact: stop playback.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_stop()
	set name = "Managed Positional Demo: Stop"
	USR_ADMIN_ONLY
	var/mob/user = usr
	if (src.stop_sound_loop())
		user?.show_text("Stopped [src].")
	else
		user?.show_text("[src] is not playing.", "red")

/// Admin-interact: pause or resume playback without losing the synchronized timeline.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_pause_or_resume()
	set name = "Managed Positional Demo: Pause/Resume"
	USR_ADMIN_ONLY
	var/mob/user = usr
	if (!src.managed_sound_loop)
		user?.show_text("[src] is not playing.", "red")
		return

	var/paused = !src.managed_sound_loop.paused
	src.managed_sound_loop.set_paused(paused)
	user?.show_text("[paused ? "Paused" : "Resumed"] [src].")

/// Admin-interact: change the sound file used by the demo loop. Restarts active playback.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_set_song()
	set name = "Managed Positional Demo: Set Song"
	USR_ADMIN_ONLY
	var/mob/user = usr
	var/new_sound = input(user, "Choose the sound file for this demo speaker.", "Set Song", src.loop_sound) as sound|null
	if (isnull(new_sound))
		return

	var/was_playing = src.managed_sound_loop ? TRUE : FALSE
	var/was_paused = src.managed_sound_loop?.paused
	src.loop_sound = new_sound
	if (was_playing)
		src.stop_sound_loop()
		if (src.start_sound_loop() && was_paused)
			src.managed_sound_loop.set_paused(TRUE)

	user?.show_text("Set [src]'s sound to [src.loop_sound].")

/// Admin-interact: change the base managed positional volume.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_set_volume()
	set name = "Managed Positional Demo: Set Volume"
	USR_ADMIN_ONLY
	var/mob/user = usr
	var/new_volume = tgui_input_number(user, "Base volume before distance falloff.", "Set Volume", default = clamp(src.loop_volume, 0, 200), max_value = 200, min_value = 0, round_input = FALSE)
	if (isnull(new_volume))
		return

	src.loop_volume = clamp(new_volume, 0, 200)
	src.managed_sound_loop?.set_volume(src.loop_volume)
	user?.show_text("Set [src]'s volume to [src.loop_volume].")

/// Admin-interact: change the pitch/frequency multiplier.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_set_pitch()
	set name = "Managed Positional Demo: Set Pitch"
	USR_ADMIN_ONLY
	var/mob/user = usr
	var/default_pitch = clamp(src.loop_pitch, -4, 4)
	if (!default_pitch)
		default_pitch = 1
	var/new_pitch = tgui_input_number(user, "Pitch/frequency multiplier. Negative values play backwards.", "Set Pitch", default = default_pitch, max_value = 4, min_value = -4, round_input = FALSE)
	if (isnull(new_pitch))
		return

	if (!new_pitch)
		new_pitch = 1
	src.loop_pitch = new_pitch
	src.managed_sound_loop?.set_pitch(src.loop_pitch)
	user?.show_text("Set [src]'s pitch to [src.loop_pitch].")

/// Admin-interact: relink passive demo emitters in range.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_refresh_emitters()
	set name = "Managed Positional Demo: Refresh Emitters"
	USR_ADMIN_ONLY
	var/mob/user = usr
	if (!src.managed_sound_loop)
		user?.show_text("[src] is not playing.", "red")
		return

	var/emitters_added = src.refresh_emitters()
	user?.show_text("Linked [emitters_added] passive emitter[s_es(emitters_added)].")

/// Admin-interact: toggle whether normal hand controls do anything.
/obj/machinery/loudspeaker/positional_multi_emitter_demo/proc/admin_toggle_hand_controls()
	set name = "Managed Positional Demo: Toggle Hand Controls"
	USR_ADMIN_ONLY
	var/mob/user = usr
	src.hand_controls_enabled = !src.hand_controls_enabled
	user?.show_text("[src]'s hand controls are now [src.hand_controls_enabled ? "enabled" : "disabled"].")

TYPEINFO(/obj/machinery/loudspeaker/positional_multi_emitter_demo/passive)
	admin_procs = null

/// Passive multi-emitter demo node. Place these near a multi-emitter demo speaker. Toggle it on and off and they should link up
/obj/machinery/loudspeaker/positional_multi_emitter_demo/passive
	name = "positional multi-emitter demo node"
	desc = "A passive loudspeaker used as an extra emitter for a nearby multi-emitter demo speaker."
	starts_on = FALSE

	New()
		. = ..()
		START_TRACKING
	disposing()
		STOP_TRACKING
		. = ..()

/obj/machinery/loudspeaker/positional_multi_emitter_demo/passive/attack_hand(mob/user)
	user?.show_text("[src] is a passive emitter node.")
	return
