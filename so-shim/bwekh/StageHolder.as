package bwekh
{
	import flash.display.Stage;

	/**
	 * The player puts its stage here before it loads a game that needs it in its main class's
	 * constructor (bwekh.appStage reads it). On Android there is no NativeWindow to ask: the
	 * player loads the bwekh classes into a domain of their own first, sets this, and loads the
	 * game into a child of that domain.
	 */
	public class StageHolder
	{
		public static var stage:Stage;
	}
}
