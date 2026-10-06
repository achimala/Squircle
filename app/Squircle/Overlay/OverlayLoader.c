// Runs when dyld loads the injected framework, before the host app's main().
extern void squircle_overlay_start(void);
__attribute__((constructor)) static void squircle_overlay_load(void) { squircle_overlay_start(); }
