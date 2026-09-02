// THE UNIVERSAL VR GRENADE.
//
// Slot 9. Select it and it is in your hand. Hold that hand's fire to open the
// pin window; take the pin with your opposite hand or with your teeth; swing
// your arm and let go of fire to throw it.
//
// ONE CLASS, NOT TWO. An earlier cut had a "pouch" weapon in slot 9 that
// produced a separate grenade object into your hand through RS_Held -- which
// meant a weapon, an inventory item, a grab-policy workaround and a held-object
// lifecycle all kept in step, every bit of it scaffolding around the fact that
// a slot number belongs to a Weapon. The grenade IS the weapon. What leaves
// your hand is the only other actor, and it exists only once it is in the air.
//
// WHAT THAT BUYS, beyond being smaller:
//   - no RS_GrabPolicy dependency, and no deriving from Inventory to sneak past
//     a hardcoded table with no extension point.
//   - no RS_Held slot to take, hold, release or leak.
//   - which hand it is in is a fact the engine already knows (bOffhandWeapon),
//     not something to track.
//
// STILL BORROWED, because these were solved already:
//   RS_Swing / RS_Throw   the peak of your arm's motion over the last ~180ms,
//                         which is the throw.
//   RS_Reach              palm centre, and the grab oval the opposite hand has
//                         to put on the grenade to take the pin.

class RSVG_Ammo : Ammo
{
	Default
	{
		Inventory.Amount 10;
		Inventory.MaxAmount 20;
		Ammo.BackpackAmount 5;
		Ammo.BackpackMaxAmount 40;
		Inventory.Icon "";
		Tag "Grenades";
	}
}


class RS_VRGrenade : Weapon
{
	// Ints, not an enum and not a Name. ZScript has no Name constants, and these
	// get compared and printed -- which an int does and a Name does not.
	const GS_SAFE    = 0;   // pin in, lever on. Inert.
	const GS_PULLING = 1;   // the ring physically coming out -- frames 8 and 9
	const GS_COOK    = 2;   // pin out, lever held down by your grip

	// Sprite letters, which MODELDEF maps onto model frames. Named rather than
	// written as bare numbers, because "frame 4" says nothing and FR_LEVER_A
	// says what you would see.
	const FR_SAFE    = 0;   // A -- ring and lever
	const FR_PULL_A  = 1;   // B -- ring going
	const FR_PULL_B  = 2;   // C -- ring nearly gone
	const FR_LEVER_A = 3;   // D -- pin out, lever held
	const FR_LIVE    = 6;   // G -- lever flown

	// Long enough that the ring reads as pulled rather than swapped, short
	// enough that it is not a cutscene.
	const PULL_TICS  = 8;

	int  gState;
	int  pullTic;
	// -1 MEANS NOT LIT, AND IT MUST BE SET EXPLICITLY.
	//
	// ZScript zero-initialises fields, so a fresh grenade arrives with fuse == 0
	// -- which the tick below reads as "the fuse has just run out" and detonates
	// in your hand on the first tic you hold it. A sentinel whose unset value is
	// indistinguishable from its worst outcome is the wrong shape, so the boolean
	// below is the real gate and the number is only the count.
	int  fuse;
	bool lit;
	int  lastTickTic;
	bool wasTrig;       // the window, edge-detected
	bool wasOtherFire;  // the opposite hand's own trigger
	bool wasFaceNear;   // face gesture, edge-detected on arrival
	int  faceTic;       // consecutive tics held at the face -- see the dwell note

	Actor prop;         // the drawn model, riding the controller
	int   propHand;

	Default
	{
		Weapon.SlotNumber 9;
		Weapon.SelectionOrder 3000;
		Weapon.AmmoType "RSVG_Ammo";
		Weapon.AmmoUse 1;
		Weapon.AmmoGive 0;
		Weapon.Kickback 0;
		+WEAPON.NOALERT;
		+WEAPON.NOAUTOFIRE;
		+WEAPON.CHEATNOTWEAPON;
		+INVENTORY.UNDROPPABLE;

		// TAG DELIBERATELY AVOIDS THE WORD "GRENADE".
		//
		// ModelSwapper token-matches weapon tags against its own table, which
		// carries a "grenade" -> MS_BD_nade entry complete with an animation set
		// whose "fire" is Brutal Doom's pin-pull-and-throw. A tag containing the
		// word matched it, and this weapon drew a BD grenade in the hand and
		// looped BD's throw on it forever. Nothing is wrong on ModelSwapper's
		// side -- it matched exactly what it was told to match.
		Tag "Frag";
	}

	override void PostBeginPlay()
	{
		Super.PostBeginPlay();
		fuse     = -1;
		lit      = false;
		gState   = GS_SAFE;
		propHand = -1;
	}

	// GetCVar, NOT FindCVar, AND THE DIFFERENCE IS EVERY SLIDER IN THIS FILE.
	//
	// Every cvar here is declared `user` scope, and a userinfo cvar is per-player:
	// FindCVar looks only at the global table and cannot see one. It does not
	// error at runtime -- it returns null, so every read fell through to its
	// hardcoded fallback and the menu quietly drove nothing. Gravity stayed at the
	// code default however the slider was set, and so did everything else.
	//
	// GetCVar takes the player the cvar belongs to. RS_Reach.Flag/Num in
	// RS_VR_Unified have always done it this way; this file did not, and that is
	// the whole bug.
	static bool Flag(String n, bool d)
	{
		CVar c = CVar.GetCVar(n, players[consoleplayer]);
		return c ? c.GetBool() : d;
	}
	static double Num(String n, double d)
	{
		CVar c = CVar.GetCVar(n, players[consoleplayer]);
		return c ? c.GetFloat() : d;
	}

	// Which physical hand this weapon is in. The engine already knows.
	int Hand() const { return bOffhandWeapon ? 1 : 0; }

	bool InHand() const
	{
		if (!Owner || !Owner.player) return false;
		let p = Owner.player;
		return (p.ReadyWeapon == self || p.OffhandWeapon == self);
	}

	// Which button is this hand's trigger. Everything else here is written as
	// HOLDING hand and OPPOSITE hand, never main/off -- a grenade can be in
	// either and the gesture is the same. This is the one place the physical
	// side matters, because the two buttons are named for it.
	static bool Trigger(PlayerInfo p, int hand)
	{
		return (hand == 0) ? ((p.cmd.buttons & BT_ATTACK) != 0)
		                   : ((p.cmd.buttons & BT_OFFHANDATTACK) != 0);
	}

	void PullPin()
	{
		if (gState != GS_SAFE) return;
		gState = GS_PULLING;
		pullTic = 0;
		A_StartSound("rsvg/pin", CHAN_BODY);

		// WHEN THE FUSE LIGHTS IS THE WHOLE FEEL, and it is a switch because
		// both answers are defensible and only a headset can choose.
		//
		//   rsvg_cook ON (default) -- the fuse starts HERE. Holding a live one is
		//     dangerous and cooking works. The pressure comes from holding the
		//     thing rather than from watching a meter fill.
		//
		//   rsvg_cook OFF -- it starts when the lever flies, as a real grenade
		//     does. Safe, and the throw carries no tension.
		if (Flag("rsvg_cook", false) && !lit)
		{
			lit  = true;
			fuse = int(clamp(Num("rsvg_fuse", 3.0), 0.5, 10.0) * 35.0);
		}
	}

	// ---- THE DRAWN MODEL ---------------------------------------------------
	//
	// SEATED BY THE RENDERER, NOT THE PLAYSIM. The prop carries FollowMainHand /
	// FollowOffHand, so its transform comes from GetWeaponTransform at DRAW rate
	// -- the same wire the world hands ride. Welded to the controller, with no
	// collision and no tic-rate smear.
	//
	// A psprite is the obvious alternative and is wrong here: a psprite is drawn
	// relative to your eye, so it is never at a real place in the room -- which
	// is the whole point of throwing it from where your arm actually is.
	// WHICHEVER WAY IT IS DRAWN, ONLY ONE OF THEM AT A TIME.
	//
	// The weapon psprite always exists -- its Ready state carries the JGRN sprite
	// the MODELDEF binds to. In world-actor mode it is hidden by alpha rather than
	// by giving the state a TNT1 sprite, because a state cannot be swapped at
	// runtime and TNT1 would make the psprite route unreachable for good.
	private void UpdateDrawn()
	{
		bool ps = Flag("rsvg_psprite", false);

		let psp = Owner.player.FindPSprite(
			bOffhandWeapon ? PSP_OFFHANDWEAPON : PSP_WEAPON);
		if (psp) psp.alpha = ps ? 1.0 : 0.0;

		if (ps) { DropProp(); return; }
		UpdateProp();
	}

	private void UpdateProp()
	{
		int want = InHand() ? Hand() : -1;

		if (want < 0 || want != propHand)
		{
			if (prop) { prop.Destroy(); prop = null; }
			propHand = want;
		}
		if (want < 0) return;

		if (!prop)
			prop = Actor.Spawn(want == 0 ? "RS_VRGrenadeHeldMain"
			                             : "RS_VRGrenadeHeldOff", Owner.Pos);
		if (!prop) return;

		// Kept on the player for CULLING only -- the renderer takes the draw
		// transform from the controller, so the actor is here purely to stay
		// inside the view frustum. Put it anywhere else and it silently vanishes.
		prop.SetOrigin(Owner.Pos, false);

		// FRAME EVERY TIC, not only on change. The frame is renderer-owned with
		// no serialisation behind it, so a value written once and never refreshed
		// survives until the first save/load and then quietly stops.
		// ONE POSE, NEVER CHANGED. See the MODELDEF note: no frame in this mesh
		// shows the pin out without also moving the body, and moving the body
		// throws away seating that was found by hand in a headset.
		prop.frame = FR_SAFE;
	}

	private void DropProp()
	{
		if (prop) { prop.Destroy(); prop = null; }
		propHand = -1;
	}

	// ---- THE THROW ---------------------------------------------------------
	//
	// What leaves your hand is a different actor, and that split is honest: in
	// your hand it is a weapon you are holding, in the air it is an object Doom
	// is moving. Nothing pretends otherwise.
	private void ThrowIt(PlayerPawn pmo, PlayerInfo p)
	{
		int hand = Hand();
		Vector3 palm = RS_Reach.Centre(pmo, p, hand);

		// The velocity is RS_Throw's: the PEAK of your arm's motion over the last
		// ~180ms rather than its speed at the instant you let go. Your arm is
		// already slowing by then, and a throw built on that reads limp however
		// hard it felt.
		Vector3 v = RS_Throw.VelocityFor(hand, pmo, p) * Num("rsvg_throw", 1.0);

		// THE ARC.
		//
		// A grenade is TOSSED, not bowled. Tracked arm motion is mostly horizontal
		// -- you swing forward far more than you swing up -- so a throw taken
		// straight from the controller leaves flat and gravity turns it into a
		// descending line rather than an arc.
		//
		// Lift adds a fraction of the HORIZONTAL speed as upward velocity, so it
		// scales with how hard you actually threw: a gentle underarm still lobs
		// gently, a hard throw still goes flat and fast. Adding a fixed amount
		// instead would make every throw arc the same regardless of effort, which
		// is the thing that reads as scripted.
		double lift = Num("rsvg_lift", 0.35);
		if (lift > 0)
		{
			double flat = (v.x, v.y, 0).Length();
			v.z += flat * lift;
		}

		// STEPPED CLEAR OF YOUR OWN BODY. rs_held.zs found this the hard way: an
		// object released inside your own collision cylinder has its horizontal
		// step refused by P_XYMovement while P_ZMovement is not blocked the same
		// way, so the throw's forward component dies and only the upward one
		// survives. It reads as momentum turning into height.
		Vector2 dir = (v.x, v.y);
		if (dir.Length() > 0.01)
		{
			dir = dir / dir.Length();
			double clearBy = pmo.Radius + 6.0;
			palm = (palm.x + dir.x * clearBy, palm.y + dir.y * clearBy, palm.z);
		}

		let g = RS_VRGrenadeThrown(Actor.Spawn("RS_VRGrenadeThrown", palm, ALLOW_REPLACE));
		if (g)
		{
			g.target = pmo;          // credits the kill, the obituary and the score
			g.Vel    = v;
			// A cooked grenade arrives with its fuse already part burned -- that is
			// the whole point of cooking one.
			g.mFuse  = lit ? fuse
			         : int(clamp(Num("rsvg_fuse", 3.0), 0.5, 10.0) * 35.0);
			// LIVE if the pin is out -- or, with rsvg_autoarm, always: that mode
			// makes the throw itself the arming, for anyone who wants a grenade
			// and not a ritual. Off, an unpinned throw is a dud you go and fetch.
			g.mLive  = (gState != GS_SAFE) || Flag("rsvg_autoarm", false);
		}

		A_StartSound("rsvg/toss", CHAN_WEAPON);

		// Reset for the next one and spend a grenade. With none left the weapon
		// deselects itself the way any empty weapon does.
		gState  = GS_SAFE;
		lit     = false;
		fuse    = -1;
		pullTic = 0;
		DepleteAmmo(false, true);
	}

	// ---- THE GESTURES ------------------------------------------------------
	//
	// DoEffect, not an EventHandler: this runs every tic while the weapon is
	// owned, which is exactly the lifetime the state belongs to -- and it means
	// the pin state lives on the object it describes rather than in a parallel
	// table keyed by hand.
	//
	// THE TRIGGER IS A WINDOW, not a button that does something. Holding fire
	// says "I am about to do something with this"; the pin comes out only inside
	// that window, and letting go throws. Nothing can happen to the grenade while
	// your finger is off the trigger, which is what makes carrying one safe.
	override void DoEffect()
	{
		Super.DoEffect();
		if (!Owner || !Owner.player) return;
		let pmo = PlayerPawn(Owner);
		if (!pmo) return;
		let p = pmo.player;

		// A HEARTBEAT, NOT AN EVENT TRACE.
		//
		// Every other trace in this file fires on something HAPPENING -- the pin
		// coming out, the throw. That is exactly no use when the complaint is that
		// nothing happens: silence then means "it did not fire" and "this code is
		// not running at all" and "you do not even have the weapon", which are
		// three completely different faults with one symptom.
		//
		// Once a second, unconditionally, while the grenade is owned. If this line
		// is absent the weapon is not in your inventory; if it says inhand=0 it is
		// not the selected weapon; if trig never reads 1 the trigger is not
		// reaching this at all.
		if (Flag("rsvg_debug", false) && (level.maptime % 35) == 0)
			Console.Printf("[RSVG] alive: inhand=%d hand=%d trig=%d state=%d fuse=%d lit=%d ammo=%d",
				InHand(), Hand(), Trigger(p, Hand()), gState, fuse, lit,
				Owner.CountInv("RSVG_Ammo"));

		if (!Flag("rsvg_enable", true) || !InHand())
		{
			DropProp();
			wasTrig = false;
			return;
		}

		UpdateDrawn();

		int hand  = Hand();
		int other = 1 - hand;
		bool trig = Trigger(p, hand);

		// The ring coming out runs on its own clock, so the gesture that started
		// it does not have to hold a hand still while it plays.
		if (gState == GS_PULLING && ++pullTic >= PULL_TICS) gState = GS_COOK;

		// COOKING IN YOUR HAND. There is no safe outcome once the fuse is lit and
		// you keep hold of it. That is the point of the setting.
		// GATED ON lit, NOT ON THE NUMBER. See the field note.
		if (lit && fuse > 0)
		{
			fuse--;

			// AUDIBLE, ESCALATING, AND NOT A NUMBER ON SCREEN. Anything needing a
			// figure floating in the air to be legible has failed to communicate.
			// Sound keeps your eyes in the room, which is where the thing you are
			// about to throw it at lives.
						// ONE TICK A HALF SECOND, DOUBLING UNDER THE LAST SECOND.
			//
			// This was 9 tics and 4 -- about four and nine a second, which is not a
			// fuse, it is an alarm clock. The point of the sound is that you can
			// count it: a rate you can count is a rate that tells you how long you
			// have, and one you cannot just tells you something is happening.
			int period = (fuse < 35) ? 8 : 17;
			if (level.maptime - lastTickTic >= period)
			{
				lastTickTic = level.maptime;
				A_StartSound("rsvg/tick", CHAN_5, CHANF_OVERLAP,
					(fuse < 35) ? 0.85 : 0.5);
			}
		}
		else if (lit && fuse <= 0)
		{
			// IN YOUR HAND. At the player rather than the palm: this is the one
			// case where exactly where it went off is not interesting.
			lit     = false;
			fuse    = -1;
			gState  = GS_SAFE;
			pullTic = 0;

			// THE WINDOW IS FORCED SHUT, and this is why the explosion repeated.
			//
			// Both pin gestures are edge-triggered, and their edges only reset when
			// the window closes. Detonating in your hand does not close it: your
			// finger is still on the trigger and your hand is still where it was. So
			// on the very next tic the face test found itself inside the near radius
			// holding a fresh grenade, took the pin again, and blew you up again
			// three seconds later. Forever, exactly one fuse length apart.
			//
			// Marking both edges as ALREADY FIRED means nothing can arm until you let
			// go of the trigger -- which is the honest requirement anyway: one
			// deliberate act per grenade.
			wasTrig      = true;
			wasOtherFire = true;
			wasFaceNear  = true;
			DropProp();
			Actor.Spawn("RSVG_Blast", pmo.Pos, ALLOW_REPLACE);
			pmo.DamageMobj(pmo, pmo, 200, 'Explosive');
			DepleteAmmo(false, true);
			return;
		}

		// ---- RELEASE: THE THROW --------------------------------------------
		// Not gated on the pin being out. A grenade you have already lit is the
		// one you most need to be able to get rid of.
		if (wasTrig && !trig)
		{
			wasTrig = false;
			ThrowIt(pmo, p);
			if (Flag("rsvg_debug", false))
				Console.Printf("[RSVG] thrown from hand %d", hand);
			return;
		}
		wasTrig = trig;

		// ---- THE WINDOW ----------------------------------------------------
		if (!trig || gState != GS_SAFE)
		{
			wasOtherFire = false;
			wasFaceNear  = false;
			return;
		}

		Vector3 palm = RS_Reach.Centre(pmo, p, hand);

		// ---- THE OPPOSITE HAND TAKES THE PIN -------------------------------
		//
		// A PLAIN DISTANCE, palm to palm.
		//
		// This used to test the opposite hand's GRAB OVAL, on the reasoning that
		// the volume you can see should be the volume that acts. That reasoning is
		// still right and the implementation was still useless: the oval is sized
		// by rs_grab_o_scale, which is 0.025 on this install -- effectively a
		// point. Nothing is ever inside it, so the pin could never be taken.
		//
		// Borrowing another subsystem's tuning means inheriting its accidents. Its
		// own number, with its own slider, is the honest version.
		//
		// EDGE, not level: a held trigger takes one pin, not one every tic.
		Vector3 opp = RS_Reach.Centre(pmo, p, other);
		bool onIt   = (opp - palm).Length() <= Num("rsvg_pin_reach", 20.0);
		bool ofire  = Trigger(p, other);

		if (ofire && !wasOtherFire && onIt)
		{
			PullPin();
			level.VRHaptic(other, 0.7, 60.0);
			level.VRHaptic(hand,  0.4, 40.0);
			if (Flag("rsvg_debug", false))
				Console.Printf("[RSVG] pin taken by the opposite hand");
		}
		wasOtherFire = ofire;

		// ---- OR YOUR TEETH -------------------------------------------------
		//
		// TWO RADII, NOT ONE, AND THAT IS THE WHOLE FIX.
		//
		// This used to ask "is the palm within rs_use_face_reach of the HMD" -- 18
		// map units, 53 CENTIMETRES. A hand is inside that most of the time it is
		// holding anything, so the pin came out the instant the window opened and
		// the grenade went off in your hand three seconds later. Over and over.
		//
		// A single radius cannot tell "brought to my face" from "hand happens to be
		// near my head", because the two look identical at one instant. The
		// difference is a JOURNEY, so it takes two radii: the hand has to have been
		// OUTSIDE the far one before crossing the near one. Rest your hand by your
		// head all day and nothing happens; take it away and bring it back and it
		// arms again.
		//
		// Its own two numbers rather than rs_use_face_reach: that cvar is sized for
		// RS_Route's gesture, where nothing it triggers can hurt you.
		if (Flag("rsvg_face", true))
		{
			double d    = (palm - pmo.HmdPos).Length();
			// 16 UNITS IS ~47cm, MEASURED FROM THE HMD ORIGIN -- which sits between
			// your eyes, not at your mouth. 11 was chosen as "at your face" and is
			// really "pressed against your nose": once the ~15cm from eyes to chin is
			// taken off, it left almost no room to actually reach.
			//
			// It can be this generous BECAUSE of the far radius. The old bug was one
			// radius at 18 with no re-arm, so a hand resting near a head fired it
			// forever. With the journey required, a reachable near radius is safe.
			double near = Num("rsvg_face_near", 16.0);   // ~47cm -- at your face
			double far  = Num("rsvg_face_far",  24.0);   // ~70cm -- clear of it

			// AND IT HAS TO STAY THERE. THIS IS WHY YOU COULD NOT THROW A DUD.
			//
			// A baseball throw brings your hand up past your head on the way back.
			// It passes straight through this radius every single time -- the log
			// caught it at d=11.5 mid-swing against a threshold of 11 -- so the pin
			// came out during the wind-up of every throw, and there was no way to
			// throw one with the pin still in.
			//
			// Two radii were not enough because both readings of the journey are
			// satisfied by swinging through: out beyond far, then inside near. What
			// separates the two is TIME. Bringing a grenade to your mouth and
			// holding it there is deliberate and lasts; a hand passing through on
			// its way to a throw is gone in two or three tics.
			//
			// So: it has to be inside the near radius for a run of consecutive
			// tics. Leave the radius and the count resets, which is what makes a
			// fast pass through unable to accumulate one.
			int hold = int(Num("rsvg_face_hold", 12.0));

			if (d > far) wasFaceNear = false;            // re-arm
			if (d <= near) faceTic++; else faceTic = 0;

			if (faceTic >= hold && !wasFaceNear)
			{
				wasFaceNear = true;
				faceTic = 0;
				PullPin();
				level.VRHaptic(hand, 0.7, 60.0);
				if (Flag("rsvg_debug", false))
					Console.Printf("[RSVG] pin taken with your teeth");
			}
			else if (Flag("rsvg_debug", false) && (level.maptime % 10) == 0)
			{
				// The distance and both thresholds, because "it did not arm" and "it
				// armed and I could not tell" look identical from inside a headset.
				Console.Printf("[RSVG] face d=%.1f  near=%.1f far=%.1f  held=%d/%d armed=%d",
					d, near, far, faceTic, hold, wasFaceNear ? 0 : 1);
			}
		}	}

	override void OnDestroy()
	{
		DropProp();
		Super.OnDestroy();
	}

	States
	{
	// A REAL SPRITE, NOT TNT1. TNT1 is an instruction to skip the layer entirely,
	// checked before any model is considered -- so with TNT1 here the psprite
	// route could never draw anything, whatever the MODELDEF said. Hidden by
	// alpha instead when the world-actor route is in use.
	Ready:
		JGRN A 1 A_WeaponReady(WRF_NOFIRE);
		Loop;
	Deselect:
		TNT1 A 1 A_Lower;
		Loop;
	Select:
		TNT1 A 1 A_Raise;
		Loop;

	// REQUIRED, AND DELIBERATELY INERT. GZDoom refuses to compile a Weapon with
	// no Fire state -- fatal, and it takes down every pk3 after it in the load
	// order. But firing must not DO anything: the trigger is a window read
	// straight off p.cmd.buttons, and a weapon that reacted to it would fight the
	// gesture. WRF_NOFIRE above means this is never entered.
	Fire:
		TNT1 A 1;
		Goto Ready;
	Spawn:
		TNT1 A -1;
		Stop;
	}
}


// ---------------------------------------------------------------------------
// WHAT LEAVES YOUR HAND.
//
// A plain actor with a velocity, which is nearly all a thrown object needs:
// P_XYMovement and P_ZMovement give gravity, floors, ceilings, stairs, wall
// sliding and bouncing for free. That is rs_throw.zs's argument for why the
// physics module was not worth its cost here, and it holds -- the solver exists
// because a HELD object at 35Hz lags your hand, and nothing is holding this.
// ---------------------------------------------------------------------------
class RS_VRGrenadeThrown : Actor
{
	// TUMBLE, IN DEGREES PER TIC -- and these are much smaller than they look.
	//
	// They were 13 and 7, taken from RS_Main's thrown grenade. At 35 tics a
	// second that is 455 and 245 degrees PER SECOND: more than a full rotation
	// every second on one axis while another spins nearly as fast. It reads as a
	// drill bit, not a thrown object.
	//
	// 3.5 and 1.5 is about one lazy turn per two seconds. Still not a neat ratio,
	// so it never looks like it is on a metronome, which was the only part of the
	// original worth keeping.
	const SPIN_ROLL  = 3.5;
	const SPIN_PITCH = 1.5;

	int  mFuse;
	bool mLive;      // the pin was out when it left your hand
	int  lastTickTic;
	int  mAge;          // tics since it left your hand

	// LATCHED, because Tick keeps running after the actor enters its Death state.
	// Without this the fuse-expiry branch below fires again on the very next tic,
	// restarts Death, and spawns another blast -- 35 explosions a second, forever.
	// A state change is not a return: it is a request the engine honours later.
	bool mBoomed;

	Default
	{
		// PROJECTILE, AND THAT ONE WORD IS THE WHOLE DIFFERENCE.
		//
		// Doom bounces a thing off a wall in P_BounceWall, and P_XYMovement only
		// calls it FOR MISSILES. A non-missile actor with every bounce flag set
		// still just slides along the wall it hit -- the flags parse, nothing
		// refuses them, and they do nothing. That is why this rolled around like a
		// dropped tin while Brutal Doom's grenade, which is a Projectile, behaves.
		//
		// Copied from BD's HandGrenade (Grenades.txt) because it is the known-good
		// reference, including its bounce numbers, which are livelier than the ones
		// guessed here before.
		Projectile;
		-NOGRAVITY;          // Projectile sets it; a grenade has to fall
		-BLOODSPLATTER;
		-EXTREMEDEATH;

		// THRUSPECIES so it cannot detonate on the person who threw it. BD uses the
		// same guard for the same reason -- without it a missile spawned at your own
		// palm can find you on its first tic.
		+THRUSPECIES;
		Species "Marines";

		Radius 4;
		Height 4;
		Mass 5;
		Speed 30;
		Damage 0;            // the blast does the damage, not the impact
		Gravity 0.27;
		Scale 1.0;
		+MOVEWITHSECTOR;
		+SKYEXPLODE;
		BounceType "Doom";
		BounceFactor 0.5;    // BD's numbers
		WallBounceFactor 0.25;
		+BOUNCEONFLOORS;
		+BOUNCEONWALLS;
		+BOUNCEONCEILINGS;
		+CANBOUNCEWATER;
		-BOUNCEONACTORS;
		BounceSound "rsvg/bounce";
	}

	override void PostBeginPlay()
	{
		Super.PostBeginPlay();
		if (mFuse <= 0) mFuse = 105;
		lastTickTic = -1000;

		// Start the tumble somewhere random so two thrown back to back are not
		// in lockstep.
		roll  = random(0, 359);
		pitch = random(0, 359);
		frame = mLive ? RS_VRGrenade.FR_LIVE : RS_VRGrenade.FR_SAFE;
	}

	override void Tick()
	{
		Super.Tick();
		if (bDestroyed || IsFrozen() || mBoomed) return;
		mAge++;

		// THE FEEL OF THE FLIGHT, read live. Every one of these can only be
		// judged by throwing the thing in a headset, so leaving them as Default
		// properties -- fixed at class-definition time and unreachable from the
		// menu -- would make them findable only by rebuilding.
		Gravity          = RS_VRGrenade.Num("rsvg_gravity",    0.27);
		bounceFactor     = RS_VRGrenade.Num("rsvg_bounce",     0.5);
		wallBounceFactor = RS_VRGrenade.Num("rsvg_wallbounce", 0.25);

		// TUMBLING IN THE AIR, SETTLING ON THE GROUND.
		//
		// Doom bounce is a velocity multiplier and nothing more. It has no notion
		// of a body at rest, so an actor that is told to spin keeps spinning after
		// it lands -- it pirouettes on the floor forever. Neither the spin nor the
		// settle is something the playsim will do on its own; both have to be said.
		//
		// GROUNDED IS THE TEST, not speed. A grenade sliding along the floor is
		// still moving and must not tumble, and one hanging at the top of its arc
		// is barely moving and must.
		bool grounded = (Pos.Z <= floorz + 0.25);

		if (!grounded)
		{
			double sp = RS_VRGrenade.Num("rsvg_spin", 3.5);
			roll  += sp;
			pitch += sp * 0.43;   // not a neat ratio, so it never looks metronomic
		}
		else
		{
			// LIE DOWN. Eased rather than snapped: a grenade that lands at 40
			// degrees and is upright the very next tic reads as a glitch, where one
			// that rocks flat over a few tics reads as an object with weight.
			//
			// Toward the nearest flat, not toward zero. Rolling 340 degrees back to
			// 0 is the long way round for what is visually a 20 degree correction.
			double r = Normalize180(roll);
			double q = Normalize180(pitch);
			roll  = Normalize180(roll  - r * 0.25);
			pitch = Normalize180(pitch - q * 0.25);

			// And stop rolling about. Doom gives an actor no ground friction of its
			// own, so without this it slides until it meets a wall.
			double f = clamp(RS_VRGrenade.Num("rsvg_friction", 0.82), 0.1, 1.0);
			Vel.X *= f;
			Vel.Y *= f;
			if ((Vel.X, Vel.Y, 0).Length() < 0.12) { Vel.X = 0; Vel.Y = 0; }
		}

		// A DUD IS NOT RUBBISH -- IT IS A GRENADE ON THE FLOOR.
		//
		// Thrown with the pin still in, nothing happens and nothing should. But
		// leaving it as a spent projectile means a grenade you can see and cannot
		// retrieve, which is worse than it never landing. Once it has stopped it
		// becomes a pickup: walk over it, or take it with a distance grab.
		//
		// SWAPPED FOR A DIFFERENT ACTOR rather than made collectable in place,
		// because this one is a Projectile -- +MISSILE changes how it moves, what
		// it collides with and how it dies, none of which something lying on a
		// floor should inherit.
		if (!mLive)
		{
			// WHEN A DUD BECOMES SOMETHING YOU CAN PICK UP.
			//
			// Waiting for it to stop moving is the obvious rule and the wrong one: a
			// bouncing projectile micro-bounces for a long time, so a grenade lying
			// right there at your feet stays untouchable while it fidgets.
			//
			// APPROACHING IT IS THE REAL SIGNAL. You walking over to a dud is you
			// saying you want it back, so that is what converts it -- it settles the
			// moment you get close rather than on its own schedule.
			//
			// The age gate stops it converting in mid-air on the way out, which would
			// otherwise happen every throw: the grenade starts AT you, so without it
			// the proximity test is true on tic one.
			//
			// At rest is kept as a second route so one thrown into a corner you never
			// walk to still stops being a projectile.
			bool old   = mAge >= int(RS_VRGrenade.Num("rsvg_dud_delay", 35.0));
			bool near  = false;
			let pmo = players[consoleplayer].mo;
			if (pmo)
				near = (pmo.Pos - Pos).Length() <= RS_VRGrenade.Num("rsvg_dud_range", 96.0);

			if ((old && near) || (grounded && Vel.Length() < 0.15))
			{
				Actor.Spawn("RSVG_Pickup", Pos, ALLOW_REPLACE);
				Destroy();
			}
			return;
		}

		if (mFuse > 0)
		{
			mFuse--;
			int period = (mFuse < 35) ? 8 : 17;
			if (level.maptime - lastTickTic >= period)
			{
				lastTickTic = level.maptime;
				A_StartSound("rsvg/tick", CHAN_5, CHANF_OVERLAP,
					(mFuse < 35) ? 0.85 : 0.5);
			}
		}
		else if (!mBoomed)
		{
			// ONE EXIT. Now that this is a Projectile the engine can end it too --
			// striking something sends a missile to its Death state -- so the fuse
			// running out has to arrive at the same place rather than detonating by a
			// second private route that could drift from it.
			//
			// LATCHED FIRST, THEN THE STATE CHANGE. SetStateLabel does not stop this
			// function and does not stop Tick running next tic -- so without the
			// latch this branch is still true on the following tic, restarts Death,
			// and spawns another explosion. Every tic. That is the infinite blast.
			mBoomed = true;
			SetStateLabel("Death");
		}
	}

	States
	{
	Spawn:
		JGRN A -1;
		Stop;

	// REQUIRED NOW THAT THIS IS A MISSILE. A projectile that strikes something is
	// sent here by the engine, and an actor with no Death state simply vanishes --
	// so without this a grenade that hit a monster would disappear in silence
	// instead of going off.
	//
	// Walls, floors and ceilings do not come here: the bounce flags handle those
	// first. This is contact with something alive, and a grenade that hits a
	// demon in the chest going off is the right outcome anyway.
	Death:
	XDeath:
		// PIN STILL IN? THEN THIS IS NOT AN EXPLOSION. The engine sends a
		// projectile here when it strikes something alive (or the sky), with
		// no regard for the dud logic in Tick -- so an UNARMED grenade that
		// hit a demon went off exactly like a live one. It bounced off the
		// demon; it is still a grenade. Drop it where it hit, the same way
		// the Tick path does when a dud settles.
		TNT1 A 0 A_JumpIf(!mLive, "Dud");
		// DAMAGE HERE, NOT IN THE EFFECT ACTOR. A_Explode credits the calling
		// actor's target as the killer -- fired from the blast instead, the player
		// loses the kill, the obituary and the score. RS_Main's own grenade carries
		// this same note for the same reason.
		TNT1 A 0 A_NoBlocking;
		TNT1 A 0 A_StartSound("rsvg/explode", CHAN_AUTO);
		TNT1 A 0 A_StartSound("rsvg/farexpl", CHAN_7);
		TNT1 A 0 A_SpawnItemEx("RSVG_Blast", 0, 0, 0, 0, 0, 0, 0, SXF_NOCHECKPOSITION);
		TNT1 A 1 A_Explode(85, 200, 1);
		TNT1 A 1 A_Explode(75, 255, 1);
		Stop;
	Dud:
		TNT1 A 0 A_SpawnItemEx("RSVG_Pickup", 0, 0, 0, 0, 0, 0, 0, SXF_NOCHECKPOSITION);
		Stop;
	}
}


// The drawn stand-in while it is in your hand. Two classes because MODELDEF
// binds per class and a Follow flag names one specific controller; nothing
// distinguishes them but that.
class RS_VRGrenadeHeldProp : Actor
{
	Default
	{
		+NOGRAVITY; +NOBLOCKMAP; +NOINTERACTION; +DONTSPLASH;
		Radius 1; Height 1;
		RenderStyle "Normal";
	}
	States
	{
	Spawn:
		// A real sprite, never TNT1: TNT1 is an instruction to skip the actor
		// entirely, checked before any model is considered.
		JGRN A -1;
		Stop;
	}
}

class RS_VRGrenadeHeldMain : RS_VRGrenadeHeldProp {}
class RS_VRGrenadeHeldOff  : RS_VRGrenadeHeldProp {}


// Everyone starts with grenades. Gated on a cvar so a mod that would rather
// place them as map pickups can switch the freebie off.
//
// GIVEN BY AN EVENT HANDLER, not by a player class: this has to work under
// Brutal Doom, Project Brutality and vanilla alike, and every one of them ships
// its own PlayerPawn. Touching player classes would mean a patch per mod, which
// is the exact thing "universal" rules out.
class RS_VRGrenadeHandler : EventHandler
{
	// SETTINGS MIGRATION, AND WHY IT HAS TO EXIST.
	//
	// A CVARINFO default only applies where the value is NOT already saved in the
	// ini. So every default corrected after someone has played once reaches
	// everybody EXCEPT the person who hit the bug -- which is exactly backwards,
	// and it is why "I fixed the gravity" was untrue for the one install that
	// mattered. RS_VR_Unified's own CVARINFO carries this warning in its header.
	//
	// rsvg_cfgver is the way out: a NEW cvar has no saved value anywhere, so it
	// reads 0 exactly once per install and never again. Bump it when a default
	// changes for a reason a player should not have to know about.
	//
	// Deliberately NOT a blanket reset -- it corrects the specific values that
	// were wrong and leaves seating, fuse length and everything else alone. A
	// migration that flattens hand-tuned numbers is worse than the bug.
	const CFG_VERSION = 1;

	private void Migrate()
	{
		let v = CVar.GetCVar("rsvg_cfgver", players[consoleplayer]);
		if (!v || v.GetInt() >= CFG_VERSION) return;

		// Doom gravity is ~2.7x earth, so 0.7 made every throw a descending line.
		// 0.27 is the arc. Only corrected if it is still sitting at the old value:
		// anything else is a number someone chose.
		let g = CVar.GetCVar("rsvg_gravity", players[consoleplayer]);
		if (g && g.GetFloat() > 0.5) g.SetFloat(0.27);

		v.SetInt(CFG_VERSION);
		Console.Printf("[RSVG] settings updated to v%d", CFG_VERSION);
	}

	override void PlayerSpawned(PlayerEvent e)
	{
		Migrate();
		if (!RS_VRGrenade.Flag("rsvg_start", true)) return;
		let pmo = players[e.PlayerNumber].mo;
		if (!pmo) return;
		if (!pmo.FindInventory("RS_VRGrenade"))
			pmo.GiveInventory("RS_VRGrenade", 1);
		let am = Ammo(pmo.FindInventory("RSVG_Ammo"));
		if (am && am.Amount < 10) am.Amount = 10;
	}
}


// THE DUD ON THE FLOOR.
//
// A plain pickup, so both routes to it work without either being taught about
// grenades: walking over it is Doom's own touch, and the distance grab reaches
// it through RS_GrabPolicy's catch-all Inventory rule.
class RSVG_Pickup : CustomInventory
{
	Default
	{
		Radius 8;
		Height 8;
		+DROPPED;
		Inventory.PickupMessage "Picked the grenade back up";
		Inventory.PickupSound "rsvg/pin";
		Tag "Frag";
	}
	States
	{
	Spawn:
		JGRN A -1;
		Stop;
	Pickup:
		TNT1 A 0 A_GiveInventory("RSVG_Ammo", 1);
		Stop;
	}
}
