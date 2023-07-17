package kiss;

#if macro
import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.PositionTools;
import sys.io.File;
import haxe.io.Path;
using haxe.io.Path;
import kiss.Helpers;
using kiss.Helpers;
using tink.MacroApi;

#end

import kiss.Kiss;
import kiss.ReaderExp;
import kiss.Prelude;
import kiss.cloner.Cloner;
using StringTools;
import hscript.Parser;
import hscript.Interp;

typedef Continuation = () -> Void;
typedef AsyncCommand = (AsyncEmbeddedScript, Continuation) -> Void;

class ObjectInterp<T> extends Interp {
    var obj:T;
    var fields:Map<String,Bool> = []; 
    public function new(obj:T) {
        this.obj = obj;
        
        for (field in Type.getInstanceFields(Type.getClass(obj))) {
            fields[field] = true;
        }

        super();
    }

    override function resolve(id:String):Dynamic {
        var fieldVal = Reflect.field(obj, id);
        if (fieldVal != null)
            return fieldVal;
        else
            return super.resolve(id);
    }

    // TODO every method of setting variables should try to set them on the object,
    // but there are a lot of them and I might have missed some.

    override function setVar(name:String, v:Dynamic) {
        if (Reflect.field(obj, name) != null) {
            Reflect.setField(obj, name, v);
        } else {
            super.setVar(name, v);
        }
    }
 
	public override function expr( e : hscript.Expr ) : Dynamic {
        var curExpr = e;
        #if hscriptPos
		var e = e.e;
		#end
        switch( e ) {
            case ECall(e,params):
                switch( hscript.Tools.expr(e) ) {
                    case EIdent(name) if (fields.exists(name)):
                        var args = new Array();
                        for( p in params )
                            args.push(expr(p));
                        return call(obj,expr(e),args);
                    default:
                }
            default:
        }
        return super.expr(curExpr);
    }
}

/**
    Utility class for making statically typed, debuggable, ASYNC-BASED embedded Kiss-based DSLs.
    Examples are in the hollywoo project.
**/
class AsyncEmbeddedScript {
    private var instructions:Array<AsyncCommand> = null;
    private var breakPoints:Map<Int, () -> Bool> = [];
    private var onBreak:AsyncCommand = null;
    private var lastInstructionPointer = -1;
    private var labels:Map<String,Int> = [];
    private var noSkipInstructions:Map<Int,Bool> = [];
    
    private var parser = new Parser();
    private var interp:ObjectInterp<AsyncEmbeddedScript>;
    public var interpVariables(get, null):Map<String,Dynamic>;
    private function get_interpVariables() {
        return interp.variables;
    }

    private var hscriptInstructions:Map<Int,String> = [];    
    private function hscriptInstructionFile() return "";

    public function setBreakHandler(handler:AsyncCommand) {
        onBreak = handler;
    }

    public function addBreakPoint(instruction:Int, ?condition:() -> Bool) {
        if (condition == null) {
            condition = () -> true;
        }
        breakPoints[instruction] = condition;
    }

    public function removeBreakPoint(instruction:Int) {
        breakPoints.remove(instruction);
    }

    public function new() {
        interp = new ObjectInterp(this);
        kiss.KissInterp.prepare(interp);
        if (hscriptInstructionFile().length > 0) {
            #if (sys || hxnodejs)
            var cacheJson:haxe.DynamicAccess<String> = haxe.Json.parse(sys.io.File.getContent(hscriptInstructionFile()));
            for (key => value in cacheJson) {
                hscriptInstructions[Std.parseInt(key)] = value;
            }
            #end
        }
    }

    private function resetInstructions() {}

    public function instructionCount() { 
        if (instructions == null)
            resetInstructions();
        return instructions.length;
    }

    #if test
    public var ranHscriptInstruction = false;
    #end
    private function runHscriptInstruction(instructionPointer:Int, cc:Continuation) {
        #if test
        ranHscriptInstruction = true;
        #end
        interp.variables['cc'] = cc;
        if (printCurrentInstruction)
            Prelude.print(hscriptInstructions[instructionPointer]);
        interp.execute(parser.parseString(hscriptInstructions[instructionPointer]));
    }

    private function runInstruction(instructionPointer:Int, withBreakPoints = true) {
        lastInstructionPointer = instructionPointer;
        if (instructions == null)
            resetInstructions();
        if (withBreakPoints && breakPoints.exists(instructionPointer) && breakPoints[instructionPointer]()) {
            if (onBreak != null) {
                onBreak(this, () -> runInstruction(instructionPointer, false));
            }
        }
        var continuation = if (instructionPointer < instructions.length - 1) {
            () -> {
                // runInstruction may be called externally to skip through the script.
                // When this happens, make sure other scheduled continuations are canceled
                // by verifying that lastInstructionPointer hasn't changed
                if (lastInstructionPointer == instructionPointer) {
                    runInstruction(instructionPointer + 1);
                }
            };
        } else {
            () -> {};
        }
        if (hscriptInstructions.exists(instructionPointer)) {
            runHscriptInstruction(instructionPointer, continuation);
        } else {
            instructions[instructionPointer](this, continuation);
        }
    }

    public function run(withBreakPoints = true) {
        runInstruction(0, withBreakPoints);
    }

    private function skipToInstruction(ip:Int) {
        var lastCC = ()->runInstruction(ip);
        // chain together the unskippable instructions prior to running the requested ip
        var noSkipList = [];
        for (cIdx in lastInstructionPointer+1... ip) {
            if (noSkipInstructions.exists(cIdx)) {
                noSkipList.push(cIdx);
            }
        }
        if (noSkipList.length > 0) {
            var cc = null;
            cc = ()->{
                if (noSkipList.length == 0) {
                    lastCC();
                } else {
                    var inst = noSkipList.shift();
                    lastInstructionPointer = inst;
                    instructions[inst](this, cc);
                }
            };
            cc();
        } else {
            lastCC();
        }

        // TODO remember whether breakpoints were requested
    }

    public function skipToNextLabel() {
        var labelPointers = [for (ip in labels) ip];
        labelPointers.sort(Reflect.compare);
        for (ip in labelPointers) {
            if (ip > lastInstructionPointer) {
                skipToInstruction(ip);
                break;
            }
        }
    }

    public function skipToLabel(name:String) {
        var ip = labels[name];
        if (lastInstructionPointer > ip) {
            throw "Rewinding AsyncEmbeddedScript is not implemented";
        }
        skipToInstruction(ip);
    }

    public function labelRunners():Map<String,Void->Void> {
        return [for (label => ip in labels) label => () -> skipToInstruction(ip)];
    }

    public var printCurrentInstruction = true;

    #if macro
    public static function build(dslHaxelib:String, dslFile:String, scriptFile:String):Array<Field> {
        // trace('AsyncEmbeddedScript.build $dslHaxelib $dslFile $scriptFile');
        var k = Kiss.defaultKissState();

        k.file = scriptFile;
        var classPath = Context.getPosInfos(Context.currentPos()).file;
        var loadingDirectory = Path.directory(classPath);
        var classFields = []; // Kiss.build() will already include Context.getBuildFields()

        var hscriptInstructions:Map<String,String> = [];
        var cache:Map<String,String> = [];
        var cacheFile = scriptFile.withoutExtension().withoutDirectory() + ".cache.json";
        if (sys.FileSystem.exists(cacheFile)) {
            var cacheJson:haxe.DynamicAccess<String> = haxe.Json.parse(sys.io.File.getContent(cacheFile));
            for (key => value in cacheJson)
                cache[key] = value;
        }

        var hscriptInstructionFile = scriptFile.withoutExtension().withoutDirectory() + ".hscript.json";

        var commandList:Array<Expr> = [];
        var labelsList:Array<Expr> = [];
        var noSkipList:Array<Expr> = [];

        var labelNum = 0;
        k.macros["label"] = (wholeExp:ReaderExp, args:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(1, 1, '(label <label>)');
            var label = Prelude.symbolNameValue(args[0]);
            label = '${++labelNum}. '.lpad("0", 5) + label;
            labelsList.push(macro labels[$v{label}] = $v{commandList.length});
            
            wholeExp.expBuilder().callSymbol("cc", []);
        };

        k.macros["noSkip"] = (wholeExp:ReaderExp, args:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(1, null, '(noSkip <body...>)');
            noSkipList.push(macro noSkipInstructions[$v{commandList.length}] = true);

            wholeExp.expBuilder().begin(args);
        }

        if (dslHaxelib.length > 0) {
            dslFile = Path.join([Helpers.libPath(dslHaxelib), dslFile]);
        }

        // This brings in the DSL's functions and global variables.
        // As a side-effect, it also fills the KissState with the macros and reader macros that make the DSL syntax
        classFields = classFields.concat(Kiss.build(dslFile, k));

        if (Lambda.count(cache) > 0) {
            classFields.push({
                name: "hscriptInstructionFile",
                access: [AOverride],
                pos: Context.currentPos(),
                kind: FFun({
                    args: [],
                    expr: macro return $v{hscriptInstructionFile}
                })
            });
        }

        scriptFile = Path.join([loadingDirectory, scriptFile]);
        
        Context.registerModuleDependency(Context.getLocalModule(), scriptFile);
        k.fieldList = [];
        Kiss._try(() -> {
            #if profileKiss
            Kiss.measure('Compiling kiss: $scriptFile', () -> {
            #end
                function process(nextExp) {
                    var cacheKey = Reader.toString(nextExp.def);
                    if (cache.exists(cacheKey)) {
                        hscriptInstructions[Std.string(commandList.length)] = cache[cacheKey];
                        commandList.push(macro null);
                        return;
                    }

                    nextExp = Kiss.macroExpand(nextExp, k);
                    var stateChanged = k.stateChanged;
                    
                    // Allow packing multiple commands into one exp with a (commands <...>) statement
                    switch (nextExp.def) {
                        case CallExp({pos: _, def: Symbol("commands")}, 
                        commands):
                            for (exp in commands) {
                                process(exp);
                            }
                            return;
                        default:
                    }
                    
                    var exprString = Reader.toString(nextExp.def);
                    var fieldCount = k.fieldList.length;
                    var expr = Kiss.readerExpToHaxeExpr(nextExp, k);
                    if (expr == null || Kiss.isEmpty(expr))
                        return;
                    expr = macro { if (printCurrentInstruction) Prelude.print($v{exprString}); $expr; };
                    expr = expr.expr.withMacroPosOf(nextExp);
                    if (expr != null) {
                        var c = macro function(self, cc) {
                            $expr;
                        };
                        // If the expression didn't change the KissState when macroExpanding, it can be cached
                        if (!stateChanged)
                            cache[cacheKey] = expr.toString();

                        commandList.push(c.expr.withMacroPosOf(nextExp));
                    }

                    // This return is essential for type unification of concat() and push() above... ugh.
                    return;
                }
                Reader.readAndProcess(Stream.fromFile(scriptFile), k, process);
                null;
            #if profileKiss
            });
            #end
        });

        classFields = classFields.concat(k.fieldList);

        classFields.push({
            pos: PositionTools.make({
                min: 0,
                max: File.getContent(scriptFile).length,
                file: scriptFile
            }),
            name: "resetInstructions",
            access: [APrivate, AOverride],
            kind: FFun({
                ret: null,
                args: [],
                expr: macro {
                    this.instructions = [$a{commandList}];
                    $b{labelsList};
                    $b{noSkipList};
                }
            })
        });

        sys.io.File.saveContent(cacheFile, haxe.Json.stringify(cache));
        sys.io.File.saveContent(hscriptInstructionFile, haxe.Json.stringify(hscriptInstructions));

        return classFields;
    }
    #end
}
