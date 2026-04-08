package options;
import options.Option;

class PSliceSubState extends BaseOptionsMenu {
    public function new() {
        title = Language.getPhrase("vslice_menu","P-Slice settings");
        rpcTitle = "P-Slice settings menu";
        var option:Option = new Option('Freeplay dynamic coloring',
			'Enables dynamic freeplay background color. Disable this if you prefer original V-slice freeplay menu colors',
			'vsliceFreeplayColors',
			BOOL);
		addOption(option);
		
		#if sys
		var option:Option = new Option('Logging type',
			'Controls verbosity of the game\'s logs',
			'loggingType',
			STRING,["None","Console","File"]);
		addOption(option);
		#end
		var option:Option = new Option('Force "New" tag',
			'If enabled will force every uncompleted song to show "new" tag even if it\'s disabled',
			'vsliceForceNewTag',
			BOOL);
		addOption(option);

		#if MULTITHREADED_LOADING
		var option:Option = new Option('Multithreaded Caching', //Name
		"If checked, enables multithreaded loading, which improves loading times but with a low chance for the game to freeze while loading a song.", //Description
		'cacheOnCPU',
		BOOL);
		addOption(option);
		#end

		#if STRICT_LOADING_SCREEN
		var option:Option = new Option('Strict Loading Screen', //Name
		"If checked, the game will unload the UI assets first, and then preload the song data (useful for low-memory devices)", //Description
		'strictLoadingScreen',
		BOOL);
		addOption(option);
		#end

        super();
    }
}