package mikolka.stages.scripts;

import flixel.FlxObject;
import flixel.math.FlxMath;
import psychlua.LuaUtils;
import openfl.geom.Point;
import substates.GameOverSubstate;
import flixel.FlxCamera.FlxCameraFollowStyle;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import objects.Note;
using StringTools;

/**
 * VSliceEvents — native Haxe port of VSliceGeneral.hx (HScript).
 * Logic is translated 1:1 from VSliceGeneral. Only the mechanism differs:
 * HScript callbacks (onUpdatePost, onBeatHit etc.) become BaseStage overrides.
 */
class VSliceEvents extends BaseStage
{
	// ── Defaults (mirrors VSliceGeneral constants exactly) ────────────────────

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

	// ── State (mirrors VSliceGeneral vars exactly) ────────────────────────────

	// Separate follow point — PlayState never touches this object.
	// tweenCameraToPosition tweens this; onUpdatePost writes scroll from it.
	var camFollowPoint:FlxObject = new FlxObject(0, 0, 1, 1);

	var curCamera = {zoom: 1.0, bop: 1.0};

	var camZoomRate:Float     = DEFAULT_RATE;
	var camZoomRateOffset:Float = 0.0;
	var camZoomingVSlice:Bool = false;

	var followTweenVSlice:Bool = false;
	var zoomTweenVSlice:Bool   = false;

	var isCamFollowVSlice:Bool = false;
	var isCamZoomVSlice:Bool   = false;
	var isCameraBop:Bool       = false;

	var followTween:FlxTween;
	var zoomTween:FlxTween;
	var scrollTween:FlxTween;
	var playerScrollTween:FlxTween;
	var opponentScrollTween:FlxTween;

	var playerScrollMult:Float   = 1.0;
	var opponentScrollMult:Float = 1.0;
	var playerScrollObj   = {v: 1.0};
	var opponentScrollObj = {v: 1.0};

	// ── Lifecycle ─────────────────────────────────────────────────────────────

	override function createPost():Void
	{
		// Expose so Lua/HScript siblings can call these
		game.setOnHScript('tweenCameraToPosition', tweenCameraToPosition);
		game.setOnHScript('tweenCameraZoom',       tweenCameraZoom);
		game.setOnHScript('getFollowCharacter',    getFollowCharacter);
		game.setOnHScript('getFollowPoint',        getFollowPoint);

		// Mirror VSliceGeneral onCreatePost exactly:
		//   camFollowPoint.setPosition(game.camFollow.x, game.camFollow.y);
		//   curCamera.zoom = game.defaultCamZoom;
		camFollowPoint.setPosition(game.camFollow.x, game.camFollow.y);
		curCamera.zoom = game.defaultCamZoom;
		curCamera.bop  = 1.0;

		game.setOnScripts('isMoveCameraEvent', false);
		game.setOnScripts('camZoomRateOffset', 0.0);
		game.setOnScripts('vsliceEventsNative', true);
	}

	// ── update — mirrors VSliceGeneral's onUpdatePost exactly ─────────────────

	override function update(elapsed:Float):Void
	{
		super.update(elapsed);

		// Per-strumline scroll speeds
		if (playerScrollMult != 1.0 || opponentScrollMult != 1.0)
		{
			game.notes.forEachAlive(function(daNote:Note) {
				final target:Float = daNote.mustPress ? playerScrollMult : opponentScrollMult;
				if (Math.abs(daNote.multSpeed - target) > 0.001)
					daNote.multSpeed = target;
			});
		}

		// Camera follow — VSliceGeneral onUpdatePost:
		//   if (!game.isCameraOnForcedPos && isCamFollowVSlice) {
		//       if (FlxG.camera.target != camFollowPoint) {
		//           FlxG.camera.followLerp = 0;
		//           FlxG.camera.scroll.set(camFollowPoint.x - width/2, camFollowPoint.y - height/2);
		//       }
		//   }
		// When target == camFollowPoint (set by followPsychCamera's FlxG.camera.follow call),
		// Flixel handles scroll automatically with lerp=0. We only force-write scroll
		// when target is null (set by tweenCameraToPosition).
		if (!(@:privateAccess game.isCameraOnForcedPos) && isCamFollowVSlice && !game.endingSong)
		{
			if (FlxG.camera.target != camFollowPoint)
			{
				FlxG.camera.followLerp = 0;
				FlxG.camera.scroll.set(
					camFollowPoint.x - FlxG.camera.width  / 2,
					camFollowPoint.y - FlxG.camera.height / 2
				);
			}
		}
		else if (isCamFollowVSlice && game.endingSong)
		{
			// Song is ending (cutscene playing) — hand camera back to game.camFollow.
			// First sync game.camFollow to camFollowPoint's current position so the
			// camera stays exactly where it is — no snap back to BF/dad position.
			if (followTween != null) { followTween.cancel(); followTween = null; }
			game.camFollow.setPosition(camFollowPoint.x, camFollowPoint.y);
			isCamFollowVSlice = false;
			FlxG.camera.follow(game.camFollow, LOCKON, 0);
		}

		// Camera zoom — VSliceGeneral onUpdatePost:
		if (isCamZoomVSlice)
		{
			if (isCameraBop) camZoomingVSlice = true;

			if (camZoomingVSlice)
			{
				game.camZooming = false;
				curCamera.bop = FlxMath.lerp(1, curCamera.bop,
					Math.exp(-elapsed * 3.125 * game.camZoomingDecay * game.playbackRate));
				game.camHUD.zoom = FlxMath.lerp(1, game.camHUD.zoom,
					Math.exp(-elapsed * 3.125 * game.camZoomingDecay * game.playbackRate));
			}

			FlxG.camera.zoom = curCamera.zoom + (camZoomingVSlice ? (curCamera.bop - 1) : 0);
		}
		else
		{
			if (isCameraBop) game.camZooming = true;
		}
	}

	// ── Note hit hooks (mirrors VSliceGeneral) ────────────────────────────────

	override function goodNoteHit(note:Note):Void
	{
		if (isCamZoomVSlice) camZoomingVSlice = true;
		game.camZooming = true;
	}

	override function opponentNoteHit(note:Note):Void
	{
		if (isCamZoomVSlice) camZoomingVSlice = true;
	}

	// ── Beat/Section hit (mirrors VSliceGeneral onBeatHit/onSectionHit) ───────

	override function beatHit():Void
	{
		// Guard camZoomRate > 0 BEFORE the modulo — rate=0 means "never bop"
		// but x % 0 is a division by zero crash on native targets.
		if (camZoomRate > 0)
		{
			final beatMod = Math.round(curBeat - camZoomRateOffset) % Math.round(camZoomRate);

			if (isCamZoomVSlice && camZoomingVSlice && FlxG.camera.zoom < 1.35
				&& ClientPrefs.data.camZooms && beatMod == 0)
			{
				curCamera.bop    += 0.015 * game.camZoomingMult;
				game.camHUD.zoom += 0.03  * game.camZoomingMult;
			}

			if (!isCamZoomVSlice && game.camZooming && FlxG.camera.zoom < 1.35
				&& ClientPrefs.data.camZooms && beatMod == 0)
			{
				game.camGame.zoom += 0.015 * game.camZoomingMult;
				game.camHUD.zoom  += 0.03  * game.camZoomingMult;
			}
		}
	}

	override function sectionHit():Void
	{
		if (PlayState.SONG.notes[curSection] != null)
		{
			if (!isCamZoomVSlice && game.camZooming && FlxG.camera.zoom < 1.35
				&& ClientPrefs.data.camZooms)
			{
				game.camGame.zoom -= 0.015 * game.camZoomingMult;
				game.camHUD.zoom  -= 0.03  * game.camZoomingMult;
			}
		}
	}

	// ── Event handler (mirrors VSliceGeneral onEvent exactly) ─────────────────

	override function eventCalled(eventName:String, value1:String, value2:String,
		flValue1:Null<Float>, flValue2:Null<Float>, strumTime:Float):Void
	{
		var v1:Dynamic = value1;
		var v2:Dynamic = value2;

		switch (eventName)
		{
			case 'FocusCamera':
				if (v1 == '' && v2 == '') followPsychCamera(true);
				else
				{
					if (@:privateAccess game.isCameraOnForcedPos) return;

					v1 = (v1 : String).split(',').map(s -> s.trim());
					v2 = (v2 : String).split(',').map(s -> s.trim());

					var targetX:Float  = parseFloatNull(v1[0]) ?? DEFAULT_POS;
					var targetY:Float  = parseFloatNull(v1[1]) ?? DEFAULT_POS;
					final char:String  = parseStrNull(v2[0]) ?? Std.string(DEFAULT_POS);
					final duration:Float = parseFloatNull(v2[1]) ?? DEFAULT_DURATION;
					final ease:String  = parseStrNull(v2[2]) ?? DEFAULT_FOCUS_EASE;
					final easeDir:String = parseStrNull(v2[3]) ?? DEFAULT_EASE_DIR;
					final combinedEase = combineEase(ease, easeDir);

					switch (char.toLowerCase().trim())
					{
						case 'gf', 'girlfriend', '2':
							final pt = getFollowCharacter('gf');
							targetX += pt.x; targetY += pt.y;
							game.callOnScripts('onMoveCameraEvent', ['gf']);
						case 'dad', 'opponent', '1':
							final pt = getFollowCharacter('dad');
							targetX += pt.x; targetY += pt.y;
							game.callOnScripts('onMoveCameraEvent', ['dad']);
						case 'bf', 'boyfriend', '0':
							final pt = getFollowCharacter('bf');
							targetX += pt.x; targetY += pt.y;
							game.callOnScripts('onMoveCameraEvent', ['boyfriend']);
						case '-1':
							// raw position, no character offset
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
							final durSeconds = Conductor.stepCrochet * duration / 1000;
							tweenCameraToPosition(targetX, targetY, durSeconds, combinedEase, true);
					}

					game.setOnScripts('isMoveCameraEvent', true);
				}

			case 'ZoomCamera':
				if (v1 == '' && v2 == '') { isCamZoomVSlice = false; zoomTweenVSlice = false; }
				else
				{
					v2 = (v2 : String).split(',').map(s -> s.trim());

					final zoom:Float        = parseFloatNull(v1) ?? DEFAULT_ZOOM;
					final duration:Float    = parseFloatNull(v2[0]) ?? DEFAULT_DURATION;
					final ease:String       = parseStrNull(v2[1]) ?? DEFAULT_EASE;
					final isDirectMode:Bool = (parseStrNull(v2[2]) ?? DEFAULT_MODE) == 'direct';
					final easeDir:String    = parseStrNull(v2[3]) ?? DEFAULT_EASE_DIR;
					final combinedEase      = combineEase(ease, easeDir);

					switch (ease.toUpperCase().trim())
					{
						case 'INSTANT':
							tweenCameraZoom(zoom, 0, isDirectMode);
						default:
							final durSeconds = Conductor.stepCrochet * duration / 1000;
							tweenCameraZoom(zoom, durSeconds, isDirectMode, combinedEase, true);
					}
				}

			case 'SetCameraBop':
				if (v1 == '' && v2 == '') resetCameraRate();
				else
				{
					isCameraBop = true;

					v2 = (v2 : String).split(',').map(s -> s.trim());

					camZoomRate = parseFloatNull(v1) ?? DEFAULT_RATE;

					final intensity:Float = parseFloatNull(v2[0]) ?? DEFAULT_BOP_INTENSITY;
					game.camZoomingMult   = intensity;

					final offset:Float    = parseFloatNull(v2[1]) ?? 0.0;
					camZoomRateOffset     = offset;
					game.setOnScripts('camZoomRateOffset', offset);
				}

			case 'SetTargetBopSpeed':
				final target = (parseStrNull(v1) ?? 'boyfriend').toLowerCase().trim();
				final bopRate:Float = parseFloatNull(v2) ?? 1.0;
				switch (target)
				{
					case 'boyfriend' | 'bf' | 'player':
						if (game.boyfriend != null) game.boyfriend.danceEveryNumBeats = Std.int(bopRate);
					case 'dad' | 'opponent':
						if (game.dad != null) game.dad.danceEveryNumBeats = Std.int(bopRate);
					case 'girlfriend' | 'gf':
						if (game.gf != null) game.gf.danceEveryNumBeats = Std.int(bopRate);
					default:
				}

			case 'ScrollSpeed':
				v2 = (v2 : String).split(',').map(s -> s.trim());

				final scroll:Float       = parseFloatNull(v1) ?? 1.0;
				final scrollDur:Float    = parseFloatNull(v2[0]) ?? DEFAULT_DURATION;
				final scrollEase:String  = parseStrNull(v2[1]) ?? DEFAULT_EASE;
				final scrollDir:String   = parseStrNull(v2[2]) ?? DEFAULT_EASE_DIR;
				final absolute:Bool      = parseBoolNull(v2[3]) ?? false;
				final strumline:String   = parseStrNull(v2[4]) ?? 'both';
				final combinedScroll     = combineEase(scrollEase, scrollDir);

				final baseSpeed:Float    = absolute ? 1.0 : (PlayState.SONG.speed ?? 1.0);
				final targetSpeed:Float  = scroll * baseSpeed;

				switch (strumline.toLowerCase().trim())
				{
					case 'player':
						if (playerScrollTween != null) playerScrollTween.cancel();
						if (scrollEase.toUpperCase() == 'INSTANT')
							playerScrollMult = targetSpeed / game.songSpeed;
						else {
							final dur = Conductor.stepCrochet * scrollDur / 1000;
							final end = targetSpeed / game.songSpeed;
							playerScrollObj.v = playerScrollMult;
							playerScrollTween = FlxTween.tween(playerScrollObj, {v: end},
								dur / game.playbackRate, {
									ease: LuaUtils.getTweenEaseByString(combinedScroll),
									onUpdate: _ -> playerScrollMult = playerScrollObj.v
								});
						}

					case 'opponent':
						if (opponentScrollTween != null) opponentScrollTween.cancel();
						if (scrollEase.toUpperCase() == 'INSTANT')
							opponentScrollMult = targetSpeed / game.songSpeed;
						else {
							final dur = Conductor.stepCrochet * scrollDur / 1000;
							final end = targetSpeed / game.songSpeed;
							opponentScrollObj.v = opponentScrollMult;
							opponentScrollTween = FlxTween.tween(opponentScrollObj, {v: end},
								dur / game.playbackRate, {
									ease: LuaUtils.getTweenEaseByString(combinedScroll),
									onUpdate: _ -> opponentScrollMult = opponentScrollObj.v
								});
						}

					default: // both
						if (playerScrollTween   != null) playerScrollTween.cancel();
						if (opponentScrollTween != null) opponentScrollTween.cancel();
						playerScrollMult = opponentScrollMult = 1.0;
						if (scrollTween != null) scrollTween.cancel();
						if (scrollEase.toUpperCase() == 'INSTANT')
							game.songSpeed = targetSpeed;
						else {
							final dur = Conductor.stepCrochet * scrollDur / 1000;
							scrollTween = FlxTween.tween(game, {songSpeed: targetSpeed},
								dur / game.playbackRate, {
									ease: LuaUtils.getTweenEaseByString(combinedScroll)
								});
						}
				}

			case 'Camera Follow Pos':
				if (@:privateAccess game.isCameraOnForcedPos)
					if (FlxG.camera.target != game.camFollow) followPsychCamera(true);

			case 'Add Camera Zoom':
				if (isCamZoomVSlice)
				{
					curCamera.bop    += parseFloatNull(v1) ?? 0.015;
					game.camHUD.zoom += parseFloatNull(v2) ?? 0.03;
				}
		}
	}

	// ── GameOver hooks (mirrors VSliceGeneral) ────────────────────────────────

	override function gameOverStart(SubState:GameOverSubstate):Void
	{
		tweenCameraZoom(game.defaultCamZoom, DEFAULT_DURATION, true, 'expoOut');
	}

	// ── Public API (exposed to sibling scripts via setOnHScript) ──────────────

	public function getFollowCharacter(char:Dynamic):Point
	{
		final c = Std.string(char);

		switch (c)
		{
			case 'gf', 'girlfriend', '2':
				if (game.gf == null) return new Point();
				return new Point(
					game.gf.getMidpoint().x + game.gf.cameraPosition[0]    + game.girlfriendCameraOffset[0],
					game.gf.getMidpoint().y + game.gf.cameraPosition[1]    + game.girlfriendCameraOffset[1]
				);
			case 'dad', 'opponent', '1':
				if (game.dad == null) return new Point();
				return new Point(
					game.dad.getMidpoint().x + 150 + game.dad.cameraPosition[0] + game.opponentCameraOffset[0],
					game.dad.getMidpoint().y - 100 + game.dad.cameraPosition[1] + game.opponentCameraOffset[1]
				);
			default:
				if (game.boyfriend == null) return new Point();
				return new Point(
					game.boyfriend.getMidpoint().x - 100 + game.boyfriend.cameraPosition[0] + game.boyfriendCameraOffset[0],
					game.boyfriend.getMidpoint().y - 100 + game.boyfriend.cameraPosition[1] + game.boyfriendCameraOffset[1]
				);
		}
	}

	// Mirror VSliceGeneral tweenCameraToPosition exactly:
	//   isCamFollowVSlice = true; followTweenVSlice = true;
	//   camFollowPoint seeded from current scroll
	//   FlxG.camera.target = null   ← key: detaches follow, update() writes scroll manually
	public function tweenCameraToPosition(x:Float, y:Float, ?duration:Float = 0,
		?ease:String = 'linear', ?allowPlaybackRate:Bool = false):Void
	{
		if (@:privateAccess game.isCameraOnForcedPos) return;

		isCamFollowVSlice = true;
		followTweenVSlice = true;
		allowPlaybackRate = allowPlaybackRate ?? false;

		if (followTween != null) followTween.cancel();

		// Seed camFollowPoint from current scroll so tween starts from where
		// camera actually is, not where camFollowPoint was last set.
		camFollowPoint.setPosition(
			FlxG.camera.scroll.x + FlxG.camera.width  * 0.5,
			FlxG.camera.scroll.y + FlxG.camera.height * 0.5
		);

		// Detach camera from any follow target so update() can write scroll directly.
		FlxG.camera.target = null;

		if (duration <= 0)
			camFollowPoint.setPosition(x, y);
		else
		{
			followTween = FlxTween.tween(camFollowPoint,
				{x: x, y: y},
				duration / (allowPlaybackRate ? game.playbackRate : 1),
				{
					ease: LuaUtils.getTweenEaseByString(ease),
					onComplete: _ -> followTweenVSlice = false
				}
			);
		}
	}

	// Mirror VSliceGeneral tweenCameraZoom exactly:
	//   curCamera tweened directly — FlxG.camera.zoom written ONLY in update()
	public function tweenCameraZoom(zoom:Float, ?duration:Float = 0, ?direct:Bool = false,
		?ease:String = 'linear', ?allowPlaybackRate:Bool = false):Void
	{
		isCamZoomVSlice   = true;
		zoomTweenVSlice   = true;
		allowPlaybackRate = allowPlaybackRate ?? false;

		if (zoomTween != null) zoomTween.cancel();

		final base:Float       = (direct ?? false) ? FlxCamera.defaultZoom : game.defaultCamZoom;
		final targetZoom:Float = zoom * base;

		if (duration <= 0)
			curCamera.zoom = targetZoom;
		else
		{
			zoomTween = FlxTween.tween(curCamera, {zoom: targetZoom},
				duration / (allowPlaybackRate ? game.playbackRate : 1),
				{
					ease: LuaUtils.getTweenEaseByString(ease),
					onComplete: _ -> zoomTweenVSlice = false
				}
			);
		}
	}

	public function getFollowPoint():Point
	{
		final pt = isCamFollowVSlice ? camFollowPoint : game.camFollow;
		return pt != null ? new Point(pt.x, pt.y) : new Point();
	}

	// ── Private helpers ───────────────────────────────────────────────────────

	// Mirror VSliceGeneral followPsychCamera exactly:
	//   setVar('isMoveCameraEvent', !isPsych)
	//   isCamFollowVSlice = !isPsych; followTweenVSlice = false
	//   FlxG.camera.follow(isPsych ? game.camFollow : camFollowPoint, LOCKON, 0)
	// Note: when isPsych=false (VSlice mode) camera.target becomes camFollowPoint,
	// so update()'s condition (target != camFollowPoint) is FALSE — Flixel handles
	// scroll automatically with lerp=0. No manual scroll write needed.
	function followPsychCamera(isPsych:Bool = false):Void
	{
		game.setOnScripts('isMoveCameraEvent', !isPsych);

		isCamFollowVSlice = !isPsych;
		followTweenVSlice = false;

		if (followTween != null) followTween.cancel();

		FlxG.camera.follow(
			isPsych ? game.camFollow : camFollowPoint,
			FlxCameraFollowStyle.LOCKON, 0
		);
	}

	function resetCameraRate():Void
	{
		isCameraBop         = false;
		camZoomingVSlice    = false;
		game.camZooming     = false;
		camZoomRate         = DEFAULT_RATE;
		game.camZoomingMult = DEFAULT_MULT;
		camZoomRateOffset   = 0.0;
		game.setOnScripts('camZoomRateOffset', 0.0);
	}

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
