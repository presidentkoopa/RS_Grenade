// THE BLAST -- lifted whole from RS_Main (zscript/weapons/weaponfx/RS_FX_Blast.zs)
// and NAMESPACED.
//
// This is the jGrenades detonation, which RS_Main had already translated to
// ZScript 1:1. It is imported rather than rewritten because how the explosion
// LOOKS is the entire reason it was asked for, and re-expressing it could only
// lose that.
//
// Every class carries an RSVG_ prefix its original did not. RS_Main defines
// RS_Blast, RS_BlastEmber and twelve siblings, and two pk3s defining one class
// name is a FATAL, GLOBAL load error -- it stops every pk3 after it compiling.
// This pk3 has to be able to load alongside RS_Main, so it cannot carry those
// names in. Renamed mechanically: every definition and reference in one pass.


// =====================================================================
// RS_FX_Blast -- the grenade detonation.
// ---------------------------------------------------------------------
// Imported 2026-08-07 from the UAC Survival Pack's explosion set, at the
// owner's direction: he liked this explosion specifically and wanted it,
// not a substitution from our existing FX. It is layered rather than a
// single fireball -- flames, two grades of smoke, two speeds of ember,
// shrapnel, and flares -- which is why it reads better than one sprite
// animation.
//
// SPRITES: 106 lumps in sprites/rs_blast/ (JXPL flames, JSMO smoke,
// JSPK embers, JLNR/JFLR flares, JL2N flare spawner, JS17 smoke column).
// None of these prefixes existed in this tree, so nothing collides.
//
// NAMED RSVG_Blast*, NOT RS_Grenade*. Owner's call -- these are a blast
// effect, not grenade parts, and other ordnance should be able to use
// them without inheriting a grenade's name.
//
// ---------------------------------------------------------------------
// DECORATE-ISMS CORRECTED ON IMPORT (all four are compile errors here):
//
//   Game Doom            deleted -- DECORATE-only, filters nothing here
//   +DOOMBOUNCE          deprecated rename -> BounceType "Doom"
//   XScale / YScale      no such Default property -> Scale set in
//                        PostBeginPlay, because a Default block cannot
//                        express a non-uniform scale at all (the engine's
//                        scale property takes ONE float and writes both
//                        axes together)
//   Acs_executealways    the source's one ACS call, an underwater test.
//                        Replaced with a waterlevel check, which is what
//                        the rest of its own file already uses.
//
// The smoke actors' "is it underwater" jumps are kept verbatim: they are
// why this explosion doesn't leave smoke hanging inside water.
// =====================================================================

// ---------------------------------------------------------------------
// Bases
// ---------------------------------------------------------------------
class RSVG_BlastFlareBase : Actor
{
	Default
	{
		+NOINTERACTION
		+NOGRAVITY
		+CLIENTSIDEONLY
		RenderStyle "Add";
		Radius 1;
		Height 1;
		Alpha 0.4;
		Scale 0.4;
	}
}

class RSVG_BlastEmber : Actor
{
	Default
	{
		Speed 9;
		Radius 8;
		Height 1;
		Gravity 0.5;
		RenderStyle "Add";
		Scale 0.06;
		Damage 0;
		+MISSILE
		+CLIENTSIDEONLY
		+NOTELEPORT
		+NOBLOCKMAP
		+BLOODLESSIMPACT
		+FORCEXYBILLBOARD
		+DONTSPLASH
		+THRUACTORS
		+GHOST
		BounceType "Doom";      // was +DOOMBOUNCE
		BounceFactor 0.01;
	}
	States
	{
	Spawn:
		JSPK A 1 Bright A_FadeOut(0.02);
		Wait;
	Death:
		Stop;
	}
}

// ---------------------------------------------------------------------
// Flares
// ---------------------------------------------------------------------
class RSVG_BlastRedFlare : RSVG_BlastFlareBase
{
	States
	{
	Spawn:
		TNT1 A 0 NoDelay A_Jump(128, "Alt");
		JLNR A 2 Bright;
		Stop;
	Alt:
		JLNR B 2 Bright;
		Stop;
	}
}

class RSVG_BlastFlare : RSVG_BlastFlareBase
{
	Default
	{
		Alpha 1.0;
	}
	// XScale 0.8 / YScale 0.4 in the source. A Default block cannot hold
	// a non-uniform scale on this engine, so it is set here.
	override void PostBeginPlay()
	{
		Super.PostBeginPlay();
		Scale = (0.8, 0.4);
	}
	States
	{
	Spawn:
		JFLR A 2 Bright;
		JFLR AAAAAAAAAAAAAAAA 1 Bright A_FadeOut(0.11);
		Stop;
	}
}

class RSVG_BlastFlareSpawner : RSVG_BlastFlareBase
{
	States
	{
	Spawn:
		TNT1 A 0 NoDelay A_SpawnItem("RSVG_BlastFlare");
		JL2N AAA 1 Bright;
		JL2N A 5;
		Stop;
	}
}

// ---------------------------------------------------------------------
// Smoke
// ---------------------------------------------------------------------
class RSVG_BlastSmoke : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOTELEPORT
		+DONTSPLASH
		+MISSILE
		+FORCEXYBILLBOARD
		+CLIENTSIDEONLY
		+NOINTERACTION
		+NOGRAVITY
		+THRUACTORS
		BounceType "Doom";
		BounceFactor 0.5;
		Radius 0;
		Height 0;
		Alpha 0.2;
		RenderStyle "Translucent";
		Scale 0.9;
		Speed 2;
	}
	States
	{
	Spawn:
		TNT1 A 0 NoDelay A_JumpIf(waterlevel > 1, "Gone");
		JSMO A 20;
		TNT1 A 0 A_JumpIf(waterlevel > 1, "Gone");
		JSMO AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2 A_FadeOut(0.01);
		Stop;
	Gone:
		TNT1 A 0;
		Stop;
	}
}

// The big slow bloom that hangs after the flash.
class RSVG_BlastSmokeHeavy : RSVG_BlastSmoke
{
	Default
	{
		Scale 1.4;
		Alpha 0.12;
	}
	States
	{
	Spawn:
		TNT1 A 0 NoDelay A_JumpIf(waterlevel > 1, "Gone");
		JSMO A 40;
		TNT1 A 0 A_JumpIf(waterlevel > 1, "Gone");
		JSMO AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2 A_FadeOut(0.002);
		Stop;
	Gone:
		TNT1 A 0;
		Stop;
	}
}

class RSVG_BlastSmokeColumn : Actor
{
	Default
	{
		Radius 0;
		Height 0;
		Alpha 0.4;
		RenderStyle "Translucent";
		Damage 0;
		+NOBLOCKMAP
		+NOTELEPORT
		+DONTSPLASH
	}
	override void PostBeginPlay()
	{
		Super.PostBeginPlay();
		Scale = (1.4, 1.0);     // XScale 1.4 in the source
	}
	States
	{
	Spawn:
		JS17 E 4;
		TNT1 A 0 A_JumpIf(waterlevel > 1, "Gone");
		JS17 ABCD 5;
		JS17 ABCD 5;
		JS17 ABCD 5;
		JS17 ABCD 5;
		JS17 ABCD 5;
		JS17 ABCD 5;
		JS17 ABCD 5;
		JS17 ABCD 5;
		JS17 E 4;
		Stop;
	Gone:
		TNT1 A 0;
		Stop;
	}
}

// ---------------------------------------------------------------------
// Embers / shrapnel
// ---------------------------------------------------------------------
class RSVG_BlastEmberFast : RSVG_BlastEmber
{
	Default
	{
		Scale 0.05;
		Speed 18;
		Gravity 0.9;
	}
	States
	{
	Spawn:
		TNT1 A 0 NoDelay A_JumpIf(waterlevel > 1, "Death");
		JSPK A 1 Bright A_FadeOut(0.02);
		Wait;
	Death:
		Stop;
	}
}

class RSVG_BlastShrapnel : RSVG_BlastEmber
{
	Default
	{
		Speed 20;
		Gravity 0.0;
		+NOGRAVITY
		Scale 0.12;
		Radius 10;
		Height 10;
		Damage 0;
		Alpha 1.0;
	}
	States
	{
	Spawn:
		JSPK AAAAAAAAAAAAAAAAA 1 Bright A_FadeOut(0.05);
		Stop;
	Death:
		Stop;
	}
}

// ---------------------------------------------------------------------
// Flames -- the body of the explosion.
// ---------------------------------------------------------------------
class RSVG_BlastFlames : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOTELEPORT
		+DONTSPLASH
		+CLIENTSIDEONLY
		+FORCEXYBILLBOARD
		+MISSILE
		+NOGRAVITY
		+THRUACTORS
		Radius 1;
		Height 1;
		RenderStyle "Add";
		Alpha 1.0;
		Scale 2.2;
		Speed 2;
		Damage 0;
	}
	States
	{
	Spawn:
		JXPL AA 3 Bright A_SpawnItem("RSVG_BlastRedFlare", 0, 0);
		JXPL BCDF 3 Bright;
		JXPL AAA 0 A_SpawnProjectile("RSVG_BlastSmoke", 0, 0,
			random(0, 360), CMF_AIMDIRECTION, random(0, 360));
		JXPL GHII 3 Bright;
		Stop;
	}
}

class RSVG_BlastFlamesMedium : RSVG_BlastFlames
{
	Default
	{
		Scale 1.3;
	}
	States
	{
	Spawn:
		JXPL AA 2 Bright A_SpawnItem("RSVG_BlastRedFlare", 0, 0);
		JXPL A 0 A_SpawnProjectile("RSVG_BlastSmoke", 0, 0,
			random(0, 360), CMF_AIMDIRECTION, random(0, 360));
		JXPL BCDF 2 Bright;
		JXPL GHII 2 Bright;
		Stop;
	}
}

// ---------------------------------------------------------------------
// RSVG_Blast -- ONE actor that fires the whole layered detonation.
//
// The source spelled this out as ~40 inline A_CustomMissile lines in the
// grenade's own Death state, twice (it picked between two near-identical
// variants with A_Jump). Putting it in one place means anything that
// wants this explosion spawns one actor, and tuning it is one edit
// rather than two.
// ---------------------------------------------------------------------
// THE SOURCE'S DETONATION, 1:1.
//
// This is J_ThrownGrenade's XDeath state transcribed verbatim: the same
// actors, in the same order, at the same counts -- 12 flames, 10 heavy
// embers, 18 fast embers, 73 shrapnel, 2 smoke columns, 4 trailing
// smokes, and the same two-stage A_Explode(85,200) / A_Explode(75,255).
//
// It is a wall of repeated TNT1 frames because that is what it is in the
// source. I rewrote it once as a cvar-driven loop and that was wrong:
// the counts ARE the explosion, and changing them changes the thing the
// owner asked for. If a shrapnel slider is wanted it goes in on top of
// this, not instead of it.
//
// The only substitutions are names -- G_* to RSVG_Blast* -- and the two
// crater actors, which are dropped: they exist to spawn MudDust /
// DirtChunk / BrownCloud off an IsOverGrass inventory token, none of
// which exist in this project, behind the source's one ACS call.
class RSVG_Blast : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOINTERACTION
		+NOGRAVITY
		+CLIENTSIDEONLY
		+DONTSPLASH
		RenderStyle "Add";
		Alpha 1.0;
	}

	// The shrapnel count, and the ONLY count that is a slider.
	//
	// The source wrote 73 as a literal wall of A's. That is the default
	// here and the state list is otherwise verbatim, so out of the box
	// this explosion is identical to the source's. The slider only
	// exists because 73 client-side actors per detonation is a
	// performance decision, and that belongs to whoever is running the
	// game rather than to whoever transcribed the file.
	action void A_RS_BlastShrapnel()
	{
		int n = 73;
		let cv = CVar.FindCVar("rs_grenade_shrapnel");
		if (cv) n = clamp(cv.GetInt(), 0, 150);

		for (int i = 0; i < n; i++)
			A_SpawnProjectile("RSVG_BlastShrapnel", 0, 0, random(0, 360),
				CMF_AIMDIRECTION, random(0, 360));
	}

	States
	{
	Spawn:
		TNT1 A 0 NoDelay A_SpawnItemEx("RSVG_BlastFlareSpawner", 0, 0, 0, 0, 0, 0, 0, SXF_NOCHECKPOSITION);
		TNT1 A 0 A_SpawnItemEx("RSVG_BlastKaboom", 0, 0, 0, 0, 0, 0, 0, SXF_NOCHECKPOSITION);
		TNT1 AAAAAAAAAAAA 0 A_SpawnProjectile("RSVG_BlastFlames", 0, 0, random(0, 360), CMF_AIMDIRECTION, random(0, 360));
		TNT1 AAAAAAAAAA 0 A_SpawnProjectile("RSVG_BlastEmber", 0, 0, random(0, 360), CMF_AIMDIRECTION, random(0, 360));
		TNT1 AAAAAAAAAAAAAAAAAA 0 A_SpawnProjectile("RSVG_BlastEmberFast", 0, 0, random(0, 360), CMF_AIMDIRECTION, random(0, 360));
		TNT1 A 0 A_RS_BlastShrapnel();
		TNT1 A 0 A_QuakeEx(3, 3, 3, 30, 0, 448, "none");
		TNT1 AA 0 A_SpawnItemEx("RSVG_BlastSmokeColumn", 0, 0, 0, 0, 0, 0, 0, SXF_NOCHECKPOSITION);
		// NOTE: the source's two A_Explode calls are NOT here -- they
		// live in the thrown grenade's own Death state, at the same
		// numbers (85/200 then 75/255). They have to: A_Explode credits
		// the calling actor's target as the killer, and this actor has
		// none, so firing the blast from here would strip the player of
		// the kill -- no obituary, no score, no Bits, no GunBonsai XP.
		// The visuals belong here; the damage belongs to the grenade.
		TNT1 A 2;
		TNT1 AAAA 8 Bright A_SpawnProjectile("RSVG_BlastSmoke", 1, 0, random(0, 360), CMF_AIMDIRECTION, random(50, 130));
		Stop;
	}
}

// G_BarrelKaboom -- the secondary burst the source fires alongside the
// main one. Kept because it is part of the look.
class RSVG_BlastKaboom : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOINTERACTION
		+NOGRAVITY
		+CLIENTSIDEONLY
		+DONTSPLASH
	}
	States
	{
	Spawn:
		TNT1 A 1;
		TNT1 AAAAAA 0 A_SpawnProjectile("RSVG_BlastFlamesMedium", 20, 0, random(0, 360), CMF_AIMDIRECTION, random(0, 180));
		Stop;
	}
}
