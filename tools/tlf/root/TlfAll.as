package
{
	import flash.display.Sprite;
	import flashx.textLayout.BuildInfo;
	import flashx.textLayout.elements.TCYElement;
	import flashx.textLayout.elements.ParagraphFormattedElement;
	import flashx.textLayout.elements.FlowGroupElement;
	import flashx.textLayout.elements.BreakElement;
	import flashx.textLayout.elements.OverflowPolicy;
	import flashx.textLayout.elements.IConfiguration;
	import flashx.textLayout.elements.DivElement;
	import flashx.textLayout.elements.TextFlow;
	import flashx.textLayout.elements.InlineGraphicElementStatus;
	import flashx.textLayout.elements.IFormatResolver;
	import flashx.textLayout.elements.TextRange;
	import flashx.textLayout.elements.InlineGraphicElement;
	import flashx.textLayout.elements.GlobalSettings;
	import flashx.textLayout.elements.ParagraphElement;
	import flashx.textLayout.elements.LinkElement;
	import flashx.textLayout.elements.TabElement;
	import flashx.textLayout.elements.Configuration;
	import flashx.textLayout.elements.FlowLeafElement;
	import flashx.textLayout.elements.SpecialCharacterElement;
	import flashx.textLayout.elements.ContainerFormattedElement;
	import flashx.textLayout.elements.LinkState;
	import flashx.textLayout.elements.SpanElement;
	import flashx.textLayout.elements.FlowElement;
	import flashx.textLayout.elements.SubParagraphGroupElement;
	import flashx.textLayout.elements.BackgroundManager;
	import flashx.textLayout.elements.FlowValueHolder;
	import flashx.textLayout.debug.assert;
	import flashx.textLayout.debug.Debugging;
	import flashx.textLayout.edit.IInteractionEventHandler;
	import flashx.textLayout.edit.EditingMode;
	import flashx.textLayout.edit.ISelectionManager;
	import flashx.textLayout.edit.SelectionFormat;
	import flashx.textLayout.edit.SelectionState;
	import flashx.textLayout.accessibility.TextAccImpl;
	import flashx.textLayout.compose.TextLineRecycler;
	import flashx.textLayout.compose.IVerticalJustificationLine;
	import flashx.textLayout.compose.IParcelList;
	import flashx.textLayout.compose.ParcelList;
	import flashx.textLayout.compose.FlowComposerBase;
	import flashx.textLayout.compose.VerticalJustifier;
	import flashx.textLayout.compose.SimpleCompose;
	import flashx.textLayout.compose.IFlowComposer;
	import flashx.textLayout.compose.BaseCompose;
	import flashx.textLayout.compose.ComposeState;
	import flashx.textLayout.compose.TextFlowLineLocation;
	import flashx.textLayout.compose.Parcel;
	import flashx.textLayout.compose.FlowDamageType;
	import flashx.textLayout.compose.StandardFlowComposer;
	import flashx.textLayout.compose.TextFlowLine;
	import flashx.textLayout.compose.ISWFContext;
	import flashx.textLayout.compose.ITextLineCreator;
	import flashx.textLayout.events.FlowElementMouseEvent;
	import flashx.textLayout.events.DamageEvent;
	import flashx.textLayout.events.StatusChangeEvent;
	import flashx.textLayout.events.UpdateCompleteEvent;
	import flashx.textLayout.events.ModelChange;
	import flashx.textLayout.events.TextLayoutEvent;
	import flashx.textLayout.events.CompositionCompleteEvent;
	import flashx.textLayout.formats.WhiteSpaceCollapse;
	import flashx.textLayout.formats.Float;
	import flashx.textLayout.formats.BaselineOffset;
	import flashx.textLayout.formats.BaselineShift;
	import flashx.textLayout.formats.VerticalAlign;
	import flashx.textLayout.formats.Direction;
	import flashx.textLayout.formats.TextLayoutFormatValueHolder;
	import flashx.textLayout.formats.LineBreak;
	import flashx.textLayout.formats.BackgroundColor;
	import flashx.textLayout.formats.TextAlign;
	import flashx.textLayout.formats.TabStopFormat;
	import flashx.textLayout.formats.FormatValue;
	import flashx.textLayout.formats.FlowElementDisplayType;
	import flashx.textLayout.formats.TextLayoutFormat;
	import flashx.textLayout.formats.IMEStatus;
	import flashx.textLayout.formats.LeadingModel;
	import flashx.textLayout.formats.Category;
	import flashx.textLayout.formats.TextJustify;
	import flashx.textLayout.formats.TLFTypographicCase;
	import flashx.textLayout.formats.TextDecoration;
	import flashx.textLayout.formats.JustificationRule;
	import flashx.textLayout.formats.ITextLayoutFormat;
	import flashx.textLayout.formats.ITabStopFormat;
	import flashx.textLayout.formats.BlockProgression;
	import flashx.textLayout.property.UintWithEnumProperty;
	import flashx.textLayout.property.IntProperty;
	import flashx.textLayout.property.Property;
	import flashx.textLayout.property.NumberWithEnumProperty;
	import flashx.textLayout.property.UintProperty;
	import flashx.textLayout.property.TabStopsProperty;
	import flashx.textLayout.property.BooleanProperty;
	import flashx.textLayout.property.NumberProperty;
	import flashx.textLayout.property.NumberOrPercentProperty;
	import flashx.textLayout.property.IntWithEnumProperty;
	import flashx.textLayout.property.EnumStringProperty;
	import flashx.textLayout.property.ArrayProperty;
	import flashx.textLayout.property.NumberOrPercentOrEnumProperty;
	import flashx.textLayout.property.StringProperty;
	import flashx.textLayout.container.ColumnState;
	import flashx.textLayout.container.ISandboxSupport;
	import flashx.textLayout.container.ContainerController;
	import flashx.textLayout.container.ScrollPolicy;
	import flashx.textLayout.factory.StringTextLineFactory;
	import flashx.textLayout.factory.TruncationOptions;
	import flashx.textLayout.factory.TextLineFactoryBase;
	import flashx.textLayout.factory.TextFlowTextLineFactory;
	import flashx.textLayout.external.WeakRef;
	import flashx.textLayout.utils.GeometryUtil;
	import flashx.textLayout.utils.CharacterUtil;
	import flashx.textLayout.utils.LocaleUtil;
	import flashx.textLayout.conversion.ITextExporter;
	import flashx.textLayout.conversion.TLFormatImporter;
	import flashx.textLayout.conversion.TextLayoutImporter;
	import flashx.textLayout.conversion.ITextImporter;
	import flashx.textLayout.conversion.TextConverter;
	import flashx.textLayout.conversion.IFormatImporter;
	import flashx.textLayout.conversion.PlainTextExporter;
	import flashx.textLayout.conversion.ConversionType;
	import flashx.undo.IOperation;
	import flashx.undo.UndoManager;
	import flashx.undo.IUndoManager;
	import flashx.textLayout.edit.TextClipboard;
	import flashx.textLayout.edit.SelectionFormatState;
	import flashx.textLayout.edit.IEditManager;
	import flashx.textLayout.edit.TextScrap;
	import flashx.textLayout.edit.Mark;
	import flashx.textLayout.edit.ParaEdit;
	import flashx.textLayout.edit.EditManager;
	import flashx.textLayout.edit.SelectionManager;
	import flashx.textLayout.edit.TextFlowEdit;
	import flashx.textLayout.edit.ElementRange;
	import flashx.textLayout.events.SelectionEvent;
	import flashx.textLayout.events.FlowOperationEvent;
	import flashx.textLayout.operations.ApplyElementIDOperation;
	import flashx.textLayout.operations.CompositeOperation;
	import flashx.textLayout.operations.DeleteTextOperation;
	import flashx.textLayout.operations.FlowOperation;
	import flashx.textLayout.operations.SplitParagraphOperation;
	import flashx.textLayout.operations.InsertTextOperation;
	import flashx.textLayout.operations.CopyOperation;
	import flashx.textLayout.operations.FlowTextOperation;
	import flashx.textLayout.operations.ModifyInlineGraphicOperation;
	import flashx.textLayout.operations.PasteOperation;
	import flashx.textLayout.operations.ClearFormatOnElementOperation;
	import flashx.textLayout.operations.ApplyTCYOperation;
	import flashx.textLayout.operations.RedoOperation;
	import flashx.textLayout.operations.InsertInlineGraphicOperation;
	import flashx.textLayout.operations.ApplyElementStyleNameOperation;
	import flashx.textLayout.operations.ClearFormatOperation;
	import flashx.textLayout.operations.CutOperation;
	import flashx.textLayout.operations.ApplyLinkOperation;
	import flashx.textLayout.operations.ApplyFormatOperation;
	import flashx.textLayout.operations.ApplyElementUserStyleOperation;
	import flashx.textLayout.operations.UndoOperation;
	import flashx.textLayout.operations.FlowElementOperation;
	import flashx.textLayout.operations.ApplyFormatToElementOperation;
	import flashx.textLayout.container.TextContainerManager;
	import flashx.textLayout.utils.NavigationUtil;

	/**
	 * Text Layout Framework 1.0 (build 595) as one SWF, compiled by AIR's own compiler (see
	 * build-tlf.ps1). Referencing every public definition pulls the whole framework in.
	 */
	public class TlfAll extends Sprite
	{
		public static const ALL:Array = [
			flashx.textLayout.BuildInfo,
			flashx.textLayout.elements.TCYElement,
			flashx.textLayout.elements.ParagraphFormattedElement,
			flashx.textLayout.elements.FlowGroupElement,
			flashx.textLayout.elements.BreakElement,
			flashx.textLayout.elements.OverflowPolicy,
			flashx.textLayout.elements.IConfiguration,
			flashx.textLayout.elements.DivElement,
			flashx.textLayout.elements.TextFlow,
			flashx.textLayout.elements.InlineGraphicElementStatus,
			flashx.textLayout.elements.IFormatResolver,
			flashx.textLayout.elements.TextRange,
			flashx.textLayout.elements.InlineGraphicElement,
			flashx.textLayout.elements.GlobalSettings,
			flashx.textLayout.elements.ParagraphElement,
			flashx.textLayout.elements.LinkElement,
			flashx.textLayout.elements.TabElement,
			flashx.textLayout.elements.Configuration,
			flashx.textLayout.elements.FlowLeafElement,
			flashx.textLayout.elements.SpecialCharacterElement,
			flashx.textLayout.elements.ContainerFormattedElement,
			flashx.textLayout.elements.LinkState,
			flashx.textLayout.elements.SpanElement,
			flashx.textLayout.elements.FlowElement,
			flashx.textLayout.elements.SubParagraphGroupElement,
			flashx.textLayout.elements.BackgroundManager,
			flashx.textLayout.elements.FlowValueHolder,
			flashx.textLayout.debug.assert,
			flashx.textLayout.debug.Debugging,
			flashx.textLayout.edit.IInteractionEventHandler,
			flashx.textLayout.edit.EditingMode,
			flashx.textLayout.edit.ISelectionManager,
			flashx.textLayout.edit.SelectionFormat,
			flashx.textLayout.edit.SelectionState,
			flashx.textLayout.accessibility.TextAccImpl,
			flashx.textLayout.compose.TextLineRecycler,
			flashx.textLayout.compose.IVerticalJustificationLine,
			flashx.textLayout.compose.IParcelList,
			flashx.textLayout.compose.ParcelList,
			flashx.textLayout.compose.FlowComposerBase,
			flashx.textLayout.compose.VerticalJustifier,
			flashx.textLayout.compose.SimpleCompose,
			flashx.textLayout.compose.IFlowComposer,
			flashx.textLayout.compose.BaseCompose,
			flashx.textLayout.compose.ComposeState,
			flashx.textLayout.compose.TextFlowLineLocation,
			flashx.textLayout.compose.Parcel,
			flashx.textLayout.compose.FlowDamageType,
			flashx.textLayout.compose.StandardFlowComposer,
			flashx.textLayout.compose.TextFlowLine,
			flashx.textLayout.compose.ISWFContext,
			flashx.textLayout.compose.ITextLineCreator,
			flashx.textLayout.events.FlowElementMouseEvent,
			flashx.textLayout.events.DamageEvent,
			flashx.textLayout.events.StatusChangeEvent,
			flashx.textLayout.events.UpdateCompleteEvent,
			flashx.textLayout.events.ModelChange,
			flashx.textLayout.events.TextLayoutEvent,
			flashx.textLayout.events.CompositionCompleteEvent,
			flashx.textLayout.formats.WhiteSpaceCollapse,
			flashx.textLayout.formats.Float,
			flashx.textLayout.formats.BaselineOffset,
			flashx.textLayout.formats.BaselineShift,
			flashx.textLayout.formats.VerticalAlign,
			flashx.textLayout.formats.Direction,
			flashx.textLayout.formats.TextLayoutFormatValueHolder,
			flashx.textLayout.formats.LineBreak,
			flashx.textLayout.formats.BackgroundColor,
			flashx.textLayout.formats.TextAlign,
			flashx.textLayout.formats.TabStopFormat,
			flashx.textLayout.formats.FormatValue,
			flashx.textLayout.formats.FlowElementDisplayType,
			flashx.textLayout.formats.TextLayoutFormat,
			flashx.textLayout.formats.IMEStatus,
			flashx.textLayout.formats.LeadingModel,
			flashx.textLayout.formats.Category,
			flashx.textLayout.formats.TextJustify,
			flashx.textLayout.formats.TLFTypographicCase,
			flashx.textLayout.formats.TextDecoration,
			flashx.textLayout.formats.JustificationRule,
			flashx.textLayout.formats.ITextLayoutFormat,
			flashx.textLayout.formats.ITabStopFormat,
			flashx.textLayout.formats.BlockProgression,
			flashx.textLayout.property.UintWithEnumProperty,
			flashx.textLayout.property.IntProperty,
			flashx.textLayout.property.Property,
			flashx.textLayout.property.NumberWithEnumProperty,
			flashx.textLayout.property.UintProperty,
			flashx.textLayout.property.TabStopsProperty,
			flashx.textLayout.property.BooleanProperty,
			flashx.textLayout.property.NumberProperty,
			flashx.textLayout.property.NumberOrPercentProperty,
			flashx.textLayout.property.IntWithEnumProperty,
			flashx.textLayout.property.EnumStringProperty,
			flashx.textLayout.property.ArrayProperty,
			flashx.textLayout.property.NumberOrPercentOrEnumProperty,
			flashx.textLayout.property.StringProperty,
			flashx.textLayout.container.ColumnState,
			flashx.textLayout.container.ISandboxSupport,
			flashx.textLayout.container.ContainerController,
			flashx.textLayout.container.ScrollPolicy,
			flashx.textLayout.factory.StringTextLineFactory,
			flashx.textLayout.factory.TruncationOptions,
			flashx.textLayout.factory.TextLineFactoryBase,
			flashx.textLayout.factory.TextFlowTextLineFactory,
			flashx.textLayout.external.WeakRef,
			flashx.textLayout.utils.GeometryUtil,
			flashx.textLayout.utils.CharacterUtil,
			flashx.textLayout.utils.LocaleUtil,
			flashx.textLayout.conversion.ITextExporter,
			flashx.textLayout.conversion.TLFormatImporter,
			flashx.textLayout.conversion.TextLayoutImporter,
			flashx.textLayout.conversion.ITextImporter,
			flashx.textLayout.conversion.TextConverter,
			flashx.textLayout.conversion.IFormatImporter,
			flashx.textLayout.conversion.PlainTextExporter,
			flashx.textLayout.conversion.ConversionType,
			flashx.undo.IOperation,
			flashx.undo.UndoManager,
			flashx.undo.IUndoManager,
			flashx.textLayout.edit.TextClipboard,
			flashx.textLayout.edit.SelectionFormatState,
			flashx.textLayout.edit.IEditManager,
			flashx.textLayout.edit.TextScrap,
			flashx.textLayout.edit.Mark,
			flashx.textLayout.edit.ParaEdit,
			flashx.textLayout.edit.EditManager,
			flashx.textLayout.edit.SelectionManager,
			flashx.textLayout.edit.TextFlowEdit,
			flashx.textLayout.edit.ElementRange,
			flashx.textLayout.events.SelectionEvent,
			flashx.textLayout.events.FlowOperationEvent,
			flashx.textLayout.operations.ApplyElementIDOperation,
			flashx.textLayout.operations.CompositeOperation,
			flashx.textLayout.operations.DeleteTextOperation,
			flashx.textLayout.operations.FlowOperation,
			flashx.textLayout.operations.SplitParagraphOperation,
			flashx.textLayout.operations.InsertTextOperation,
			flashx.textLayout.operations.CopyOperation,
			flashx.textLayout.operations.FlowTextOperation,
			flashx.textLayout.operations.ModifyInlineGraphicOperation,
			flashx.textLayout.operations.PasteOperation,
			flashx.textLayout.operations.ClearFormatOnElementOperation,
			flashx.textLayout.operations.ApplyTCYOperation,
			flashx.textLayout.operations.RedoOperation,
			flashx.textLayout.operations.InsertInlineGraphicOperation,
			flashx.textLayout.operations.ApplyElementStyleNameOperation,
			flashx.textLayout.operations.ClearFormatOperation,
			flashx.textLayout.operations.CutOperation,
			flashx.textLayout.operations.ApplyLinkOperation,
			flashx.textLayout.operations.ApplyFormatOperation,
			flashx.textLayout.operations.ApplyElementUserStyleOperation,
			flashx.textLayout.operations.UndoOperation,
			flashx.textLayout.operations.FlowElementOperation,
			flashx.textLayout.operations.ApplyFormatToElementOperation,
			flashx.textLayout.container.TextContainerManager,
			flashx.textLayout.utils.NavigationUtil
		];
	}
}
