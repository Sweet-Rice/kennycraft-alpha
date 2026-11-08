// No sound and no music on KennyCraft. Replaces doomgeneric's s_sound.c and
// i_sound.c (and drops sounds.c, mus2mid.c, memio.c, gusconf.c, i_cdmus.c and
// every sound/music backend), so no SFX or music lump is ever looked up or
// loaded from the WAD and none of that code is in the image. These are the
// entry points the rest of the engine calls, all no-ops.
#include "doomtype.h"
#include "i_sound.h"
#include "s_sound.h"

int snd_channels = 8;
int sfxVolume = 8;      // menu and config settings, kept so the menu works
int musicVolume = 8;

void I_BindSoundVariables(void) {}
void I_InitSound(boolean use_sfx_prefix) { (void)use_sfx_prefix; }
void I_InitMusic(void) {}

void S_Init(int sfxVolume, int musicVolume) { (void)sfxVolume; (void)musicVolume; }
void S_Shutdown(void) {}
void S_Start(void) {}
void S_StartSound(void *origin, int sound_id) { (void)origin; (void)sound_id; }
void S_StopSound(mobj_t *origin) { (void)origin; }
void S_StartMusic(int music_id) { (void)music_id; }
void S_ChangeMusic(int music_id, int looping) { (void)music_id; (void)looping; }
boolean S_MusicPlaying(void) { return false; }
void S_StopMusic(void) {}
void S_PauseSound(void) {}
void S_ResumeSound(void) {}
void S_UpdateSounds(mobj_t *listener) { (void)listener; }
void S_SetMusicVolume(int volume) { (void)volume; }
void S_SetSfxVolume(int volume) { (void)volume; }
