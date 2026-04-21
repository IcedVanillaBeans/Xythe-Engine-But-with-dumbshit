package mikolka.stages.scripts;

import flixel.FlxCamera.FlxCameraFollowStyle;
import flixel.FlxObject;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import objects.Note;
import psychlua.LuaUtils;
import substates.GameOverSubstate;

/**
 * VSliceEvents — native Haxe port of VSliceGeneral.hx (HScript).
 *
 * Handles V-Slice chart events faithfully inside P-Slice's BaseStage system.
 * Replaces the original VSliceEvents.hx stub entirely.
 *
 * Supported events:
 *   FocusCamera, ZoomCamera, SetCameraBop, SetTargetBopSpeed,
 *   ScrollSpeed, PlayAnimation, Camera Follow Pos, Add Camera Zoom
 *
 * NOTE: P-Slice's PlayState only calls these BaseStage hooks via stagesFunc:
 *   createPost, eventCalled, goodNoteHit, opponentNoteHit.
 * Beat/section detection is therefore done by tracking curBeat/curSection
 * changes inside update(), which is called by Flixel automatically.
 */
class VSliceEvents extends BaseStage
{
	// ── Defaults ─────────────────────────────────────────────────────────────

	static final DEFAULT_DURATION:Float  = 4.0;
	static final DEFAULT_MODE:String     = 'direct';
	static final DEFAULT_EASE:String     = 'linear';
	static final DEFAULT_EASE_DIR:String = 'In';

	static final DEFAULT_POS:Float         = 0;
	static final DEFAULT_FOCUS_EASE:String = 'CLASSIC';

	static final DEFAULT_ZOOM:Float          = 1.0;
	static final DEFAULT_MULT:Float          = 1.0;
	static final DEFAULT_RATE:Float          = 4.0;
	static final DEFAULT_BOP_INTENSITY:Float = 1.0;

	// ── Camera follow state ───────────────────────────────────────────────────

	var camFollowPoint:FlxObject = new FlxObject(0, 0, 1, 1);

	var camZoom:Float = 1.0; // authoritative zoom target
	var camBop:Float  = 1.0; // live bop multiplier

	var camZoomRate:Float      = DEFAULT_RATE;
	var camZoomRateOffset:Float = 0.0;

	var camZoomingVSlice:Bool = false;
	var followTweenActive:Bool = false;
	var zoomTweenActive:Bool   = false;

	var isCamFollowVSlice:Bool = false;
	var isCamZoomVSlice:Bool   = false;
	var isCameraBop:Bool       = false;

	// ── Beat / section tracking ───────────────────────────────────────────────
	// P-Slice doesn't call beatHit/sectionHit on BaseStage via stagesFunc,
	// so we detect changes manually in update().

	var _lastBeat:Int    = -1;
	var _lastSection:Int = -1;

	// ── Tweens ────────────────────────────────────────────────────────────────

	var followTween:FlxTween;
	var zoomTween:FlxTween;
	var scrollTween:FlxTween;
	var playerScrollTween:FlxTween;
	var opponentScrollTween:FlxTween;

	// ── Per-strumline scroll speed multipliers ────────────────────────────────
	// effectiveSpeed = game.songSpeed × multSpeed.
	// Stored as typed struct fields — inline anonymous objects can be GC'd by
	// HScript; native Haxe struct instances are safe to tween.

	var playerScrollMult:Float   = 1.0;
	var opponentScrollMult:Float = 1.0;

	var playerScrollObj   = {v: 1.0};
	var opponentScrollObj = {v: 1.0};

	// ── BaseStage lifecycle ───────────────────────────────────────────────────

	override function createPost():Void
	{
		camFollowPoint.setPosition(game.camFollow.x, game.camFollow.y);
		camZoom = game.defaultCamZoom;

		// Expose helpers so Lua/HScript sibling scripts can call them.
		game.setOnHScript('tweenCameraToPosition', tweenCameraToPosition);
		game.setOnHScript('tweenCameraZoom', tweenCameraZoom);
		game.setOnHScript('getFollowCharacter', getFollowCharacter);
		game.setOnHScript('getFollowPoint', getFollowPoint);

		game.setOnScripts('isMoveCameraEvent', false);
		game.setOnScripts('camZoomRateOffset', 0.0);

		// Signal to VSliceGeneral.hx (HScript) that the compiled version is active.
		// VSliceGeneral checks 'vsliceEventsNative' in its onCreatePost and defers
		// to this class entirely, preventing both from handling events simultaneously.
		game.setOnScripts('vsliceEventsNative', true);
	}

	override function update(elapsed:Float):Void
	{
		super.update(elapsed);

		// ── Per-strumline scroll speeds ───────────────────────────────────────
		if (playerScrollMult != 1.0 || opponentScrollMult != 1.0)
		{
			game.notes.forEachAlive(function(daNote:Note)
			{
				final target:Float = daNote.mustPress ? playerScrollMult : opponentScrollMult;
				if (Math.abs(daNote.multSpeed - target) > 0.001)
					daNote.multSpeed = target;
			});
		}

		// ── VSlice camera follow ──────────────────────────────────────────────
		if (!(@:privateAccess game.isCameraOnForcedPos) && isCamFollowVSlice)
		{
			if (FlxG.camera.target != camFollowPoint)
			{
				FlxG.camera.followLerp = 0;
				FlxG.camera.scroll.set(
					camFollowPoint.x - FlxG.camera.width  * 0.5,
					camFollowPoint.y - FlxG.camera.height * 0.5
				);
			}
		}

		// ── VSlice camera zoom + bop ──────────────────────────────────────────
		if (isCamZoomVSlice)
		{
			if (isCameraBop) camZoomingVSlice = true;
			if (camZoomingVSlice)
			{
				game.camZooming = false;
				camBop = FlxMath.lerp(1, camBop, Math.exp(-elapsed * 3.125 * game.camZoomingDecay * game.playbackRate));
				game.camHUD.zoom = FlxMath.lerp(1, game.camHUD.zoom, Math.exp(-elapsed * 3.125 * game.camZoomingDecay * game.playbackRate));
			}
			FlxG.camera.zoom = camZoom + (camZoomingVSlice ? (camBop - 1) : 0);
		}
		else
		{
			if (isCameraBop) game.camZooming = true;
		}

		// ── Beat detection (replaces beatHit override) ────────────────────────
		final beat:Int = curBeat;
		if (beat != _lastBeat)
		{
			_lastBeat = beat;
			_onBeatHit(beat);
		}

		// ── Section detection (replaces sectionHit override) ─────────────────
		final section:Int = curSection;
		if (section != _lastSection)
		{
			_lastSection = section;
			_onSectionHit(section);
		}
	}

	function _onBeatHit(beat:Int):Void
	{
		final beatCheck:Bool = camZoomRate > 0
			&& Math.round(beat - camZoomRateOffset) % Math.round(camZoomRate) == 0;

		if (isCamZoomVSlice && camZoomingVSlice && FlxG.camera.zoom < 1.35
			&& ClientPrefs.data.camZooms && beatCheck)
		{
			camBop += 0.015 * game.camZoomingMult;
			game.camHUD.zoom += 0.03 * game.camZoomingMult;
		}

		if (!isCamZoomVSlice && game.camZooming && FlxG.camera.zoom < 1.35
			&& ClientPrefs.data.camZooms && beatCheck)
		{
			game.camGame.zoom += 0.015 * game.camZoomingMult;
			game.camHUD.zoom  += 0.03  * game.camZoomingMult;
		}
	}

	function _onSectionHit(section:Int):Void
	{
		if (PlayState.SONG.notes[section] != null)
		{
			if (!isCamZoomVSlice && game.camZooming && FlxG.camera.zoom < 1.35
				&& ClientPrefs.data.camZooms)
			{
				game.camGame.zoom -= 0.015 * game.camZoomingMult;
				game.camHUD.zoom  -= 0.03  * game.camZoomingMult;
			}
		}
	}

	// ── Note hit hooks ────────────────────────────────────────────────────────

	override function goodNoteHit(note:Note):Void
	{
		if (isCamZoomVSlice) camZoomingVSlice = true;
		game.camZooming = true;
	}

	override function opponentNoteHit(note:Note):Void
	{
		if (isCamZoomVSlice) camZoomingVSlice = true;
	}

	// ── Event handler ─────────────────────────────────────────────────────────

	override function eventCalled(eventName:String, value1:String, value2:String,
		flValue1:Null<Float>, flValue2:Null<Float>, strumTime:Float):Void
	{
		switch (eventName)
		{
			case 'FocusCamera':
				if (value1 == '' && value2 == '')
				{
					followPsychCamera(true);
				}
				else
				{
					if (@:privateAccess game.isCameraOnForcedPos) return;

					final v1 = value1.split(',').map(s -> s.trim());
					final v2 = value2.split(',').map(s -> s.trim());

					var targetX:Float  = parseFloatNull(v1[0]) ?? DEFAULT_POS;
					var targetY:Float  = parseFloatNull(v1[1]) ?? DEFAULT_POS;
					final char:String  = parseStrNull(v2[0]) ?? 'bf';
					final dur:Float    = parseFloatNull(v2[1]) ?? DEFAULT_DURATION;
					final ease:String  = parseStrNull(v2[2]) ?? DEFAULT_FOCUS_EASE;
					final edir:String  = parseStrNull(v2[3]) ?? DEFAULT_EASE_DIR;
					final combined:String = combineEase(ease, edir);

					switch (char.toLowerCase().trim())
					{
						case 'gf' | 'girlfriend' | '2':
							final pt = getFollowCharacter('gf');
							targetX += pt.x; targetY += pt.y;
							game.callOnScripts('onMoveCameraEvent', ['gf']);
						case 'dad' | 'opponent' | '1':
							final pt = getFollowCharacter('dad');
							targetX += pt.x; targetY += pt.y;
							game.callOnScripts('onMoveCameraEvent', ['dad']);
						case 'bf' | 'boyfriend' | '0':
							final pt = getFollowCharacter('bf');
							targetX += pt.x; targetY += pt.y;
							game.callOnScripts('onMoveCameraEvent', ['boyfriend']);
						case '-1': // raw position — no character offset
						default:
					}

					switch (ease.toUpperCase().trim())
					{
						case 'CLASSIC':
							followPsychCamera(false);
							camFollowPoint.setPosition(targetX, targetY);
						case 'INSTANT':
							tweenCameraToPosition(targetX, targetY, 0);
						default:
							final durSecs = Conductor.stepCrochet * dur / 1000;
							tweenCameraToPosition(targetX, targetY, durSecs, combined, true);
					}

					game.setOnScripts('isMoveCameraEvent', true);
				}

			case 'ZoomCamera':
				if (value1 == '' && value2 == '')
				{
					isCamZoomVSlice = false;
					zoomTweenActive  = false;
				}
				else
				{
					final v2 = value2.split(',').map(s -> s.trim());
					final zoom:Float  = parseFloatNull(value1) ?? DEFAULT_ZOOM;
					final dur:Float   = parseFloatNull(v2[0]) ?? DEFAULT_DURATION;
					final ease:String = parseStrNull(v2[1]) ?? DEFAULT_EASE;
					final isDirect    = (parseStrNull(v2[2]) ?? DEFAULT_MODE) == 'direct';
					final edir:String = parseStrNull(v2[3]) ?? DEFAULT_EASE_DIR;

					switch (ease.toUpperCase().trim())
					{
						case 'INSTANT':
							tweenCameraZoom(zoom, 0, isDirect);
						default:
							tweenCameraZoom(zoom, Conductor.stepCrochet * dur / 1000,
								isDirect, combineEase(ease, edir), true);
					}
				}

			case 'SetCameraBop':
				if (value1 == '' && value2 == '')
				{
					resetCameraRate();
				}
				else
				{
					isCameraBop = true;
					final v2 = value2.split(',').map(s -> s.trim());
					camZoomRate = parseFloatNull(value1) ?? DEFAULT_RATE;
					game.camZoomingMult = parseFloatNull(v2[0]) ?? DEFAULT_BOP_INTENSITY;
					camZoomRateOffset   = parseFloatNull(v2[1]) ?? 0.0;
					game.setOnScripts('camZoomRateOffset', camZoomRateOffset);
				}

			case 'SetTargetBopSpeed':
				final target = (parseStrNull(value1) ?? 'boyfriend').toLowerCase().trim();
				final rate   = Std.int(parseFloatNull(value2) ?? 1.0);
				switch (target)
				{
					case 'boyfriend' | 'bf' | 'player':   game.boyfriend.danceEveryNumBeats = rate;
					case 'dad' | 'opponent':               game.dad.danceEveryNumBeats = rate;
					case 'girlfriend' | 'gf':              game.gf.danceEveryNumBeats = rate;
					default:
						if (game.modchartSprites.exists(target))
							game.modchartSprites.get(target).danceEveryNumBeats = rate;
				}

			case 'ScrollSpeed':
				final v2 = value2.split(',').map(s -> s.trim());
				final scroll   = parseFloatNull(value1) ?? 1.0;
				final dur      = parseFloatNull(v2[0]) ?? DEFAULT_DURATION;
				final ease     = parseStrNull(v2[1]) ?? DEFAULT_EASE;
				final edir     = parseStrNull(v2[2]) ?? DEFAULT_EASE_DIR;
				final absolute = parseBoolNull(v2[3]) ?? false;
				final strum    = parseStrNull(v2[4]) ?? 'both';
				final combined = combineEase(ease, edir);

				final base:Float   = absolute ? 1.0 : (PlayState.SONG.speed ?? 1.0);
				final target:Float = scroll * base;

				switch (strum.toLowerCase().trim())
				{
					case 'player':
						if (playerScrollTween != null) playerScrollTween.cancel();
						if (ease.toUpperCase() == 'INSTANT')
						{
							playerScrollMult = target / game.songSpeed;
						}
						else
						{
							playerScrollObj.v = playerScrollMult;
							playerScrollTween = FlxTween.tween(
								playerScrollObj, {v: target / game.songSpeed},
								(Conductor.stepCrochet * dur / 1000) / game.playbackRate,
								{
									ease: LuaUtils.getTweenEaseByString(combined),
									onUpdate: _ -> playerScrollMult = playerScrollObj.v
								}
							);
						}

					case 'opponent':
						if (opponentScrollTween != null) opponentScrollTween.cancel();
						if (ease.toUpperCase() == 'INSTANT')
						{
							opponentScrollMult = target / game.songSpeed;
						}
						else
						{
							opponentScrollObj.v = opponentScrollMult;
							opponentScrollTween = FlxTween.tween(
								opponentScrollObj, {v: target / game.songSpeed},
								(Conductor.stepCrochet * dur / 1000) / game.playbackRate,
								{
									ease: LuaUtils.getTweenEaseByString(combined),
									onUpdate: _ -> opponentScrollMult = opponentScrollObj.v
								}
							);
						}

					default: // 'both'
						if (playerScrollTween   != null) playerScrollTween.cancel();
						if (opponentScrollTween != null) opponentScrollTween.cancel();
						playerScrollMult = opponentScrollMult = 1.0;
						if (scrollTween != null) scrollTween.cancel();
						if (ease.toUpperCase() == 'INSTANT')
						{
							game.songSpeed = target;
						}
						else
						{
							scrollTween = FlxTween.tween(game, {songSpeed: target},
								(Conductor.stepCrochet * dur / 1000) / game.playbackRate,
								{ease: LuaUtils.getTweenEaseByString(combined)});
						}
				}

			case 'Camera Follow Pos':
				if ((@:privateAccess game.isCameraOnForcedPos) && FlxG.camera.target != game.camFollow)
					followPsychCamera(true);

			case 'Add Camera Zoom':
				if (isCamZoomVSlice)
				{
					camBop += parseFloatNull(value1) ?? 0.015;
					game.camHUD.zoom += parseFloatNull(value2) ?? 0.03;
				}
		}
	}

	// ── Public helpers (exposed to HScript / Lua siblings) ────────────────────

	public function getFollowCharacter(char:String):FlxPoint
	{
		// Note: GameOverSubstate.instance is typed as FlxState which has no character fields,
		// so we always use game (PlayState) directly. This function only runs during gameplay.
		switch (char.toLowerCase().trim())
		{
			case 'gf' | 'girlfriend' | '2':
				if (game.gf == null) return FlxPoint.get();
				return FlxPoint.get(
					game.gf.getMidpoint().x + game.gf.cameraPosition[0] + game.girlfriendCameraOffset[0],
					game.gf.getMidpoint().y + game.gf.cameraPosition[1] + game.girlfriendCameraOffset[1]
				);
			case 'dad' | 'opponent' | '1':
				if (game.dad == null) return FlxPoint.get();
				return FlxPoint.get(
					game.dad.getMidpoint().x + 150 + game.dad.cameraPosition[0] + game.opponentCameraOffset[0],
					game.dad.getMidpoint().y - 100 + game.dad.cameraPosition[1] + game.opponentCameraOffset[1]
				);
			default: // bf
				if (game.boyfriend == null) return FlxPoint.get();
				return FlxPoint.get(
					game.boyfriend.getMidpoint().x - 100 + game.boyfriend.cameraPosition[0] + game.boyfriendCameraOffset[0],
					game.boyfriend.getMidpoint().y - 100 + game.boyfriend.cameraPosition[1] + game.boyfriendCameraOffset[1]
				);
		}
	}

	public function getFollowPoint():FlxPoint
	{
		final pt = isCamFollowVSlice ? camFollowPoint : game.camFollow;
		return pt != null ? FlxPoint.get(pt.x, pt.y) : FlxPoint.get();
	}

	public function tweenCameraToPosition(x:Float, y:Float, ?duration:Float = 0,
		?ease:String = 'linear', ?allowPlaybackRate:Bool = false):Void
	{
		if (@:privateAccess game.isCameraOnForcedPos) return;
		isCamFollowVSlice = true;
		followTweenActive = true;
		if (followTween != null) followTween.cancel();

		camFollowPoint.setPosition(
			FlxG.camera.scroll.x + FlxG.camera.width  * 0.5,
			FlxG.camera.scroll.y + FlxG.camera.height * 0.5
		);
		FlxG.camera.target = null;

		if (duration <= 0)
		{
			camFollowPoint.setPosition(x, y);
		}
		else
		{
			final rate = (allowPlaybackRate ?? false) ? game.playbackRate : 1.0;
			followTween = FlxTween.tween(camFollowPoint, {x: x, y: y}, duration / rate, {
				ease: LuaUtils.getTweenEaseByString(ease),
				onComplete: _ -> followTweenActive = false
			});
		}
	}

	public function tweenCameraZoom(zoom:Float, ?duration:Float = 0, ?direct:Bool = false,
		?ease:String = 'linear', ?allowPlaybackRate:Bool = false):Void
	{
		isCamZoomVSlice = true;
		zoomTweenActive = true;
		if (zoomTween != null) zoomTween.cancel();

		// camZoom is authoritative — do NOT sync from FlxG.camera.zoom here.
		// FlxG.camera.zoom lags one frame (synced in update()), so reading it
		// clobbers INSTANT zooms fired in the same frame before this tween starts.
		final targetZoom = zoom * ((direct ?? false) ? FlxCamera.defaultZoom : game.defaultCamZoom);

		if (duration <= 0)
		{
			camZoom = targetZoom;
		}
		else
		{
			final rate    = (allowPlaybackRate ?? false) ? game.playbackRate : 1.0;
			final zoomObj = {v: camZoom};
			zoomTween = FlxTween.tween(zoomObj, {v: targetZoom}, duration / rate, {
				ease: LuaUtils.getTweenEaseByString(ease),
				onUpdate:   _ -> camZoom = zoomObj.v,
				onComplete: _ -> { camZoom = targetZoom; zoomTweenActive = false; }
			});
		}
	}

	// ── Private helpers ───────────────────────────────────────────────────────

	function followPsychCamera(isPsych:Bool = false):Void
	{
		game.setOnScripts('isMoveCameraEvent', !isPsych);
		isCamFollowVSlice = !isPsych;
		followTweenActive = false;
		if (followTween != null) followTween.cancel();
		FlxG.camera.follow(
			isPsych ? game.camFollow : camFollowPoint,
			FlxCameraFollowStyle.LOCKON, 0
		);
	}

	function resetCameraRate():Void
	{
		isCameraBop       = false;
		camZoomRate       = DEFAULT_RATE;
		camZoomRateOffset = 0.0;
		game.camZoomingMult = DEFAULT_MULT;
		game.setOnScripts('camZoomRateOffset', 0.0);
	}

	/**
	 * Mirrors V-Slice's EASE_TYPE_DIR_REGEX logic.
	 * ease='expo' + easeDir='Out' → 'expoOut'
	 * If ease already has a direction suffix, or is linear/INSTANT/CLASSIC, returns as-is.
	 */
	inline function combineEase(ease:String, easeDir:String):String
	{
		if (ease == null || ease == '') return DEFAULT_EASE;
		final up = ease.toUpperCase();
		if (up == 'LINEAR' || up == 'INSTANT' || up == 'CLASSIC') return ease;
		if (ease.endsWith('In') || ease.endsWith('Out') || ease.endsWith('InOut')) return ease;
		return ease + (easeDir ?? DEFAULT_EASE_DIR);
	}

	inline function parseStrNull(s:String):Null<String>
		return s == '' ? null : s;

	inline function parseBoolNull(s:String):Null<Bool>
		return s == 'true' ? true : (s == 'false' ? false : null);

	inline function parseFloatNull(s:String):Null<Float>
	{
		final f = Std.parseFloat(s);
		return Math.isNaN(f) ? null : f;
	}
}
