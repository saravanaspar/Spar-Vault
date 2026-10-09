{{flutter_js}}
{{flutter_build_config}}
if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('spar_offline.js').catch(() => {
    console.warn('Spar Vault: public offline asset cache unavailable.');
  });
}
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
    fontFallbackBaseUrl: 'assets/fallback_fonts/',
    useColorEmoji: false
  }
});
