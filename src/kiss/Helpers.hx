package kiss;
#if macro

import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.PositionTools;
import hscript.Parser;
import hscript.Interp;
import kiss.Reader;
import kiss.ReaderExp;
import kiss.KissError;
import kiss.Kiss;
import kiss.ExpBuilder;
import kiss.SpecialForms;
import kiss.Prelude;
import kiss.cloner.Cloner;
import uuid.Uuid;
import sys.io.Process;
import sys.FileSystem;
import haxe.io.Path;

using uuid.Uuid;
using tink.MacroApi;
using kiss.Reader;
using kiss.Helpers;
using kiss.Kiss;
using StringTools;
using haxe.macro.ExprTools;

/**
 * Compile-time helper functions for Kiss. Don't import or reference these at runtime.
 */
class Helpers {
    public static function macroPos(exp:ReaderExp) {
        var kissPos = exp.pos;
        return PositionTools.make({
            min: kissPos.absoluteChar,
            max: kissPos.absoluteChar,
            file: kissPos.file
        });
    }

    public static function withMacroPosOf(e:ExprDef, exp:ReaderExp):Expr {
        return {
            pos: macroPos(exp),
            expr: e
        };
    }

    static function startsWithUpperCase(s:String) {
        return s.charAt(0) == s.charAt(0).toUpperCase();
    }

    public static function parseTypePath(path:String, k:KissState, ?from:ReaderExp):TypePath {
        path = replaceTypeAliases(path, k);
        return switch (parseComplexType(path, k, from)) {
            case TPath(path):
                path;
            default:
                var errorMessage = 'Haxe could not parse a type path from $path';
                if (from == null) {
                    throw errorMessage;
                } else {
                    throw KissError.fromExp(from, errorMessage);
                }
        };
    }

    public static function replaceTypeAliases(path:String, ?k:KissState) {
        var tokens = Prelude.splitByAll(path, ["->", "<", ">", ","]);
        tokens = [for (token in tokens) {
            if (k?.typeAliases.exists(token)) {
                k.typeAliases[token];
            } else {
                token;
            }
        }];
        return tokens.join("");
    }

    public static function parseComplexType(path:String, ?k:KissState, ?from:ReaderExp, mustResolve=false):ComplexType {
        if (k != null)
            path = replaceTypeAliases(path, k);

        // Trick Haxe into parsing it for us:
        var typeCheckStr = 'var thing:$path;';
        var errorMessage = 'Haxe could not parse a complex type from `$path` in `${typeCheckStr}`';

        function throwError() {
            if (from == null) {
                throw errorMessage;
            } else {
                throw KissError.fromExp(from, errorMessage);
            };
        }
        try {
            var typeCheckExpr = Context.parse(typeCheckStr, Context.currentPos());
            var t = switch (typeCheckExpr.expr) {
                case EVars([{
                    type: complexType
                }]):
                    complexType;
                default:
                    throwError();
                    return null;
            };
            if (mustResolve) {
                try {
                    var pos = if (from != null) from.macroPos() else Context.currentPos();
                    Context.resolveType(t, pos);
                } catch (e:Dynamic) {
                    errorMessage = 'Type not found: $path';
                    throwError();
                }
            }
            return t;
        } catch (err) {
            throwError();
            return null;
        }
    }

    public static function explicitTypeString(nameExp:ReaderExp, ?k:KissState):String {
        return switch (nameExp.def) {
            case MetaExp(_, innerExp):
                explicitTypeString(innerExp, k);
            case TypedExp(type, _):
                type = replaceTypeAliases(type, k);
                type;
            default: null;
        };
    }

    public static function explicitType(nameExp:ReaderExp, k:KissState):ComplexType {
        var string = explicitTypeString(nameExp, k);
        if (string == null) return null;
        return Helpers.parseComplexType(string, k, nameExp);
    }

    public static function varName(formName:String, nameExp:ReaderExp, nameType = "variable") {
        return switch (nameExp.def) {
            case Symbol(name) if (!name.contains(".")):
                name;
            case MetaExp(_, nameExp) | TypedExp(_, nameExp):
                varName(formName, nameExp);
            default:
                throw KissError.fromExp(nameExp, 'The first argument to $formName should be a $nameType name, :Typed $nameType name, and/or &meta $nameType name.');
        };
    }

    public static function makeTypeParam(param:ReaderExp, k:KissState, ?constraints:Array<ComplexType> = null):TypeParamDecl {
        if (constraints == null) constraints = [];
        switch (param.def) {
            case Symbol(name):
                return {
                    name: replaceTypeAliases(name, k),
                    constraints: constraints
                };
            case TypedExp(type, param):
                constraints.push(parseComplexType(type, k));
                return makeTypeParam(param, k, constraints);
            default:
                throw KissError.fromExp(param, "expected <GenericTypeName> or :<Constraint> <GenericTypeName>");
        }
    }

    public static function makeFunction(?name:ReaderExp, returnsValue:Bool, argList:ReaderExp, body:List<ReaderExp>, k:KissState, formName:String, typeParams:Array<ReaderExp>):Function {
        var funcName = if (name != null) {
            varName(formName, name, "function");
        } else {
            "";
        };

        var params = [for (p in typeParams) makeTypeParam(p, k)];

        var numArgs = 0;
        // Once the &opt meta appears, all following arguments are optional until &rest
        var opt = false;
        // Once the &rest meta appears, no other arguments can be declared
        var rest = false;
        var restProcessed = false;

        function makeFuncArg(funcArg:ReaderExp):FunctionArg {
            if (restProcessed) {
                throw KissError.fromExp(funcArg, "cannot declare more arguments after a &rest argument");
            }
            return switch (funcArg.def) {
                case MetaExp("rest", innerFuncArg):
                    if (funcName == "") {
                        throw KissError.fromExp(funcArg, "lambda does not support &rest arguments");
                    }

                    var typeOfRestArg = explicitTypeString(funcArg, k);
                    var isDynamicArray = switch (typeOfRestArg) {
                        case "Array<Dynamic>" | "kiss.List<Dynamic>" | "List<Dynamic>":
                            true;
                        default:
                            false;
                    };

                    // rest arguments define a Kiss special form with the function's name that wraps
                    // the rest args in a list when calling it from Kiss
                    k.specialForms[funcName] = (wholeExp:ReaderExp, args:Array<ReaderExp>, k:KissState) -> {
                        var realCallArgs = args.slice(0, numArgs);
                        var restArgs = args.slice(numArgs);
                        var arg = if (isDynamicArray) {
                            var b = funcArg.expBuilder();
                            b.let([b.typed("Array<Dynamic>", b.symbol("args")), b.list([])], [
                                for (arg in restArgs)
                                    b.callField("push", b.symbol("args"), [arg])
                            ].concat([b.symbol("args")]));
                        } else {
                            ListExp(restArgs).withPosOf(wholeExp);
                        }
                        realCallArgs.push(arg);
                        ECall(k.convert(Symbol(funcName).withPosOf(wholeExp)), realCallArgs.map(k.convert)).withMacroPosOf(wholeExp);
                    };

                    opt = true;
                    rest = true;
                    makeFuncArg(innerFuncArg);
                case MetaExp("opt", innerFuncArg):
                    opt = true;
                    makeFuncArg(innerFuncArg);
                default:
                    if (rest) {
                        restProcessed = true;
                    } else {
                        ++numArgs;
                    }
                    {
                        // These could use varName() and explicitType() but so far there are no &meta annotations for function arguments
                        name: switch (funcArg.def) {
                            case Symbol(name) | TypedExp(_, {pos: _, def: Symbol(name)}) if (name.endsWith(",")):
                                throw KissError.fromExp(funcArg, "trailing comma on function argument");
                            case Symbol(name) | TypedExp(_, {pos: _, def: Symbol(name)}) if (!name.contains(".")):
                                name;
                            default:
                                throw KissError.fromExp(funcArg, 'function argument should be a plain symbol or typed symbol');
                        },
                        type: switch (funcArg.def) {
                            case TypedExp(type, _):
                                Helpers.parseComplexType(type, k, funcArg);
                            default: null;
                        },
                        opt: opt
                    };
            };
        }

        var args:Array<FunctionArg> = switch (argList.def) {
            case ListExp(funcArgs):
                funcArgs.map(makeFuncArg);
            case CallExp(_, _):
                throw KissError.fromExp(argList, 'expected an argument list. Change the parens () to brackets []');
            default:
                throw KissError.fromExp(argList, 'expected an argument list');
        };

        var vars = [for (arg in args) {
            {
                name: arg.name,
                type: arg.type
            }
        }];

        for (v in vars) {
            k.addVarInScope(v, true);
        }

        var expr = if (body.length == 0) {
            EReturn(null).withMacroPosOf(if (name != null) name else argList);
        } else {
            var builder = body[0].expBuilder();
            var block = k.convert(builder.begin(body));

            if (returnsValue) {
                EReturn(block).withMacroPosOf(body[-1]);
            } else {
                block;
            };
        }

        for (v in vars) {
            k.removeVarInScope(v, true);
        }

        // To make function args immutable by default, we would use (let...) instead of (begin...)
        // to make the body expression.
        // But setting null arguments to default values is so common, and arguments are not settable references,
        // so function args are not immutable.
        return {
            ret: if (name != null) Helpers.explicitType(name, k) else null,
            args: args,
            expr: expr,
            params: params
        };
    }

    // The name of this function is confusing--it actually makes a Haxe `case` expression, not a switch-case expression
    public static function makeSwitchCase(caseExp:ReaderExp, k:KissState):Case {
        var guard:Expr = null;
        var restExpIndex = -1;
        var restExpName = "";
        var expNames = [];
        var listVarSymbol = null;

        var varsInScope:Array<Var> = [];
        function makeSwitchPattern(patternExp:ReaderExp):Array<Expr> {
            return switch (patternExp.def) {
                case _ if (k.hscript):
                    var patternExpr = k.forCaseParsing().convert(patternExp);
                    [switch (patternExpr.expr) {
                        case EConst(CString(_, _)):
                            patternExpr;
                        case EConst(CInt(_) | CFloat(_)):
                            patternExpr;
                        case EConst(CIdent("null")):
                            patternExpr;
                        default:
                            throw KissError.fromExp(caseExp, "case expressions in macros can only match literal values");
                    }];
                case CallExp({pos: _, def: Symbol("when")}, whenExps):
                    patternExp.checkNumArgs(2, 2, "(when <guard> <pattern>)");
                    if (guard != null)
                        throw KissError.fromExp(caseExp, "case pattern can only have one `when` or `unless` guard");
                    guard = macro Prelude.truthy(${k.convert(whenExps[0])});
                    makeSwitchPattern(whenExps[1]);
                case CallExp({pos: _, def: Symbol("unless")}, whenExps):
                    patternExp.checkNumArgs(2, 2, "(unless <guard> <pattern>)");
                    if (guard != null)
                        throw KissError.fromExp(caseExp, "case pattern can only have one `when` or `unless` guard");
                    guard = macro !Prelude.truthy(${k.convert(whenExps[0])});
                    makeSwitchPattern(whenExps[1]);
                case ListEatingExp(exps) if (exps.length == 0):
                    throw KissError.fromExp(patternExp, "list-eating pattern should not be empty");
                case ListEatingExp(exps):
                    for (idx in 0...exps.length) {
                        var exp = exps[idx];
                        switch (exp.def) {
                            case Symbol(_) | MetaExp("mut", {pos: _, def: Symbol(_)}):
                                expNames.push(exp);
                            case ListRestExp(name):
                                if (restExpIndex > -1) {
                                    throw KissError.fromExp(patternExp, "list-eating pattern cannot have multiple ... or ...<restVar> expressions");
                                }
                                restExpIndex = idx;
                                restExpName = name;
                            default:
                                throw KissError.fromExp(exp, "list-eating pattern can only contain symbols, ..., or ...<restVar>");
                        }
                    }

                    if (restExpIndex == -1) {
                        throw KissError.fromExp(patternExp, "list-eating pattern is missing ... or ...<restVar>");
                    }

                    if (expNames.length == 0) {
                        throw KissError.fromExp(patternExp, "list-eating pattern must match at least one single element");
                    }

                    var b = patternExp.expBuilder();
                    listVarSymbol = b.symbol();
                    guard = k.convert(b.callSymbol(">", [b.field("length", listVarSymbol), b.raw(Std.string(expNames.length))]));
                    makeSwitchPattern(listVarSymbol);
                default:
                    var patternExpr = k.forCaseParsing().convert(patternExp);
                    // Recurse into the pattern expr for identifiers that must be added
                    // to vars in scope:
                    function findIdents(subExpr) {
                        switch (subExpr.expr) {
                            case EConst(CIdent(name)):
                                varsInScope.push({name: name});
                            default:
                                haxe.macro.ExprTools.iter(subExpr, findIdents);
                        }
                    }

                    findIdents(patternExpr);

                    [patternExpr];
            }
        }

        return switch (caseExp.def) {
            case CallExp(patternExp, caseBodyExps):
                var pattern = makeSwitchPattern(patternExp);
                var b = caseExp.expBuilder();
                var body = if (restExpIndex == -1) {
                    for (v in varsInScope) {
                        k.addVarInScope(v, true, false);
                    }
                    var e = k.convert(b.begin(caseBodyExps));
                    for (v in varsInScope) {
                        k.removeVarInScope(v, true);
                    }
                    e;
                } else {
                    var letBindings = [];
                    for (idx in 0...restExpIndex) {
                        letBindings.push(expNames.shift());
                        letBindings.push(b.callSymbol("nth", [listVarSymbol, b.raw(Std.string(idx))]));
                    }
                    if (restExpName == "") {
                        restExpName = "_";
                    }
                    letBindings.push(b.symbol(restExpName));
                    var sliceArgs = [b.raw(Std.string(restExpIndex))];
                    if (expNames.length > 0) {
                        sliceArgs.push(b.callSymbol("-", [b.field("length", listVarSymbol), b.raw(Std.string(expNames.length))]));
                    }
                    letBindings.push(b.call(b.field("slice", listVarSymbol), sliceArgs));
                    while (expNames.length > 0) {
                        var idx = b.callSymbol("-", [b.field("length", listVarSymbol), b.raw(Std.string(expNames.length))]);
                        letBindings.push(expNames.shift());
                        letBindings.push(b.callSymbol("nth", [listVarSymbol, idx]));
                    }
                    var letExp = b.callSymbol("let", [b.list(letBindings)].concat(caseBodyExps));
                    k.convert(letExp);
                };
                // These prints for debugging need to be wrapped in comments because they'll get picked up by convertToHScript()
                // Prelude.print('/* $pattern */');
                // Prelude.print('/* $body */');
                // Prelude.print('/* $guard */');
                {
                    values: pattern,
                    expr: body,
                    guard: guard
                };
            default:
                throw KissError.fromExp(caseExp, "case expressions for (case...) must take the form ([pattern] [body...])");
        }
    }

    /**
        Throw a KissError if the given expression has the wrong number of arguments
    **/
    public static function checkNumArgs(wholeExp:ReaderExp, min:Null<Int>, max:Null<Int>, ?expectedForm:String) {
        ExpBuilder.checkNumArgs(wholeExp, min, max, expectedForm);
    }

    public static function removeTypeAnnotations(exp:ReaderExp):ReaderExp {
        var def = switch (exp.def) {
            case Symbol(_) | StrExp(_) | RawHaxe(_) | RawHaxeBlock(_) | Quasiquote(_):
                exp.def;
            case CallExp(func, callArgs):
                CallExp(removeTypeAnnotations(func), callArgs.map(removeTypeAnnotations));
            case ListExp(elements):
                ListExp(elements.map(removeTypeAnnotations));
            case TypedExp(type, innerExp):
                innerExp.def;
            case MetaExp(meta, innerExp):
                MetaExp(meta, removeTypeAnnotations(innerExp));
            case FieldExp(field, innerExp, safe):
                FieldExp(field, removeTypeAnnotations(innerExp), safe);
            case KeyValueExp(keyExp, valueExp):
                KeyValueExp(removeTypeAnnotations(keyExp), removeTypeAnnotations(valueExp));
            case Unquote(innerExp):
                Unquote(removeTypeAnnotations(innerExp));
            case UnquoteList(innerExp):
                UnquoteList(removeTypeAnnotations(innerExp));
            case None:
                None;
            case ListEatingExp(exps):
                ListEatingExp(exps.map(removeTypeAnnotations));
            case ListRestExp(name):
                ListRestExp(name);
            default:
                throw KissError.fromExp(exp, 'cannot remove type annotations');
        };
        return def.withPosOf(exp);
    }
    // hscript.Interp is very finicky about some edge cases.
    // This function handles them
    private static function mapForInterp(expr:Expr, k:KissState):Expr {
        return expr.map(subExp -> {
            switch (subExp.expr) {
                case ETry(e, catches):
                    catches = [for (c in catches) {
                        // hscript.Parser expects :Dynamic after the catch varname
                        {
                            type: Helpers.parseComplexType("Dynamic", k),
                            name: c.name,
                            expr: c.expr
                        };
                    }];
                    {
                        pos: subExp.pos,
                        expr: ETry(e, catches)
                    };
                default: mapForInterp(subExp, k);
            }
        });
    }

    static var parser = new Parser();
    static function compileTimeHScript(exp:ReaderExp, k:KissState) {
        var hscriptExp = mapForInterp(k.forMacroEval().convert(exp), k);
        var code = hscriptExp.toString(); // tink_macro to the rescue
        #if macrotest
        Prelude.print("Compile-time hscript: " + code);
        #end
        // Need parser external to the KissInterp to wrap parsing in an informative try-catch
        var parsed = try {
            parser.parseString(code);
        } catch (e) {
            throw KissError.fromExp(exp, 'macro-time hscript parsing failed with $e:\n$code');
        };
        return parsed;
    }

    public static function runAtCompileTimeDynamic(exp:ReaderExp, k:KissState, ?args:Map<String, Dynamic>):Dynamic {
        var parsed = compileTimeHScript(exp, k);

        // The macro interpreter gets everything a KissInterp has,
        // plus macro-specific things.
        var interp = new KissInterp();
        interp.variables.set("kissFile", k.file);
        interp.variables.set("read", Reader._assertRead.bind(_, k));
        interp.variables.set("readOr", Reader._readOr.bind(_, k));
        interp.variables.set("readExpArray", Reader._readExpArray.bind(_, _, k));
        interp.variables.set("ReaderExp", ReaderExpDef);
        interp.variables.set("nextToken", Reader.nextToken.bind(_, "a token"));
        interp.variables.set("printExp", printExp);
        interp.variables.set("macroExpand", Kiss.macroExpand.bind(_, k));
        interp.variables.set("kiss", {
            ReaderExp: {
                ReaderExpDef: ReaderExpDef
            },
            KissInterp: KissInterp,
            Prelude: Prelude
        });
        interp.variables.set("k", k.forMacroEval());
        interp.variables.set("Macros", Macros);
        interp.variables.set("Stream", Stream);
        for (name => value in k.macroVars) {
            interp.variables.set(name, value);
        }
        interp.variables.set("_setMacroVar", (name, value) -> {
            k.macroVars[name] = value;
            interp.variables.set(name, value);
        });
        interp.variables.set("KissError", KissError);

        function innerRunAtCompileTimeDynamic(innerExp:ReaderExp) {
            // in case macroVars have changed
            for (name => value in k.macroVars) {
                interp.variables.set(name, value);
            }
            var value = interp.publicExprReturn(compileTimeHScript(innerExp, k));
            if (value == null) {
                throw KissError.fromExp(exp, "compile-time evaluation returned null");
            }
            return value;
        }
        function innerRunAtCompileTime(exp:ReaderExp) {
            var v:Dynamic = innerRunAtCompileTimeDynamic(exp);
            return compileTimeValueToReaderExp(v, exp);
        }

        interp.variables.set("eval", innerRunAtCompileTimeDynamic);
        interp.variables.set("Helpers", {
            evalUnquotes: evalUnquotes.bind(_, innerRunAtCompileTime),
            runAtCompileTime: innerRunAtCompileTime,
            // TODO it is bad that Helpers functions have to manually be included here:
            explicitTypeString: Helpers.explicitTypeString,
            argList: Helpers.argList,
            bindingList: Helpers.bindingList
        });
        interp.variables.set("__interp__", interp);

        if (args != null) {
            for (arg => value in args) {
                interp.variables.set(arg, value);
            }
        }
        var value:Dynamic = interp.execute(parsed);
        if (value == null) {
            throw KissError.fromExp(exp, "compile-time evaluation returned null");
        }
        return value;
    }

    public static function runAtCompileTime(exp:ReaderExp, k:KissState, ?args:Map<String, Dynamic>):ReaderExp {
        var value = runAtCompileTimeDynamic(exp, k, args);
        var expResult = compileTimeValueToReaderExp(value, exp);
        #if macrotest
        Prelude.print('Compile-time value: ${Reader.toString(expResult.def)}');
        #end
        return expResult;
    }

    // The value could be either a ReaderExp, ReaderExpDef, Array of ReaderExp/ReaderExpDefs, or something else entirely,
    // but it needs to be a ReaderExp for evalUnquotes()
    static function compileTimeValueToReaderExp(e:Dynamic, source:ReaderExp):ReaderExp {
        return if (Std.isOfType(e, Array)) {
            var arr:Array<Dynamic> = e;
            var listExps = arr.map(compileTimeValueToReaderExp.bind(_, source));
            ListExp(listExps).withPosOf(source);
        } else if (Std.isOfType(e, Float) || Std.isOfType(e, Int)) {
            Symbol(Std.string(e)).withPosOf(source);
        } else if (Std.isOfType(e, Bool)) {
            Symbol(Std.string(e)).withPosOf(source);
        } else if (Std.isOfType(e, String)) {
            var s:String = e;
            StrExp(s).withPosOf(source);
        } else if (Std.isOfType(e, ReaderExpDef)) {
            (e : ReaderExpDef).withPosOf(source);
        } else if (e.pos != null && e.def != null) {
            (e : ReaderExp);
        } else {
            throw KissError.fromExp(source, 'Value $e cannot be used as a Kiss expression');
        }
    }

    public static function printExp(e:Dynamic, label = "") {
        var toPrint = label;
        if (label.length > 0) {
            toPrint += ": ";
        }
        var expDef = if (e.def != null) e.def else e;
        toPrint += Reader.toString(expDef);
        Prelude.printStr(toPrint);
        return e;
    }

    static function _unquoteListArray(l:ReaderExp, innerRunAtCompileTime:(ReaderExp)->Dynamic) {
        var listToInsert:Dynamic = innerRunAtCompileTime(l);
        // listToInsert could be either an array (from &rest) or a ListExp (from [list syntax])
        var newElements:Array<ReaderExp> = if (Std.isOfType(listToInsert, Array)) {
            listToInsert;
        } else {
            switch (listToInsert.def) {
                case ListExp(elements):
                    elements;
                default:
                    throw KissError.fromExp(listToInsert, ",@ can only be used with lists");
            };
        }
        return newElements;
    }

    static function evalUnquoteLists(l:Array<ReaderExp>, innerRunAtCompileTime:(ReaderExp)->Dynamic):Array<ReaderExp> {
        var idx = 0;
        while (idx < l.length) {
            switch (l[idx].def) {
                case UnquoteList(exp):
                    l.splice(idx, 1);
                    var newElements = _unquoteListArray(exp, innerRunAtCompileTime);
                    for (el in newElements) {
                        l.insert(idx++, el);
                    }
                default:
                    idx++;
            }
        }
        return l;
    }

    public static function evalUnquotes(exp:ReaderExp, innerRunAtCompileTime:(ReaderExp)->Dynamic):ReaderExp {
        var recurse = evalUnquotes.bind(_, innerRunAtCompileTime);
        var def = switch (exp.def) {
            case Symbol(_) | StrExp(_) | RawHaxe(_) | RawHaxeBlock(_):
                exp.def;
            // Crazy edge case: (,@list <exps...>)
            case CallExp({def:UnquoteList(listExp)}, callArgs):
                var newElements = _unquoteListArray(listExp, innerRunAtCompileTime);
                var wholeList = newElements.concat(callArgs).map(recurse);
                CallExp(wholeList.shift(), wholeList);
            case CallExp(func, callArgs):
                CallExp(recurse(func), evalUnquoteLists(callArgs, innerRunAtCompileTime).map(recurse));
            case ListExp(elements):
                ListExp(evalUnquoteLists(elements, innerRunAtCompileTime).map(recurse));
            case BraceExp(elements):
                BraceExp(evalUnquoteLists(elements, innerRunAtCompileTime).map(recurse));
            case TypedExp(type, innerExp):
                TypedExp(type, recurse(innerExp));
            case FieldExp(field, innerExp, safe):
                FieldExp(field, recurse(innerExp), safe);
            case KeyValueExp(keyExp, valueExp):
                KeyValueExp(recurse(keyExp), recurse(valueExp));
            case Unquote(innerExp):
                var unquoteValue:Dynamic = innerRunAtCompileTime(innerExp);
                compileTimeValueToReaderExp(unquoteValue, exp).def;
            case MetaExp(meta, innerExp):
                MetaExp(meta, recurse(innerExp));
            case HaxeMeta(name, params, innerExp):
                HaxeMeta(name, params, recurse(innerExp));
            default:
                throw KissError.fromExp(exp, 'unquote evaluation not implemented');
        };
        return def.withPosOf(exp);
    }

    public static function expBuilder(posRef:ReaderExp) return ExpBuilder.expBuilder(posRef);

    public static function checkNoEarlyOtherwise(cases:kiss.List<ReaderExp>) {
        for (i in 0...cases.length) {
            switch (cases[i].def) {
                case CallExp({pos: _, def: Symbol("otherwise")}, _) if (i != cases.length - 1):
                    throw KissError.fromExp(cases[i], "(otherwise <body...>) branch must come last in a (case <...>) expression");
                default:
            }
        }
    }

    public static function argList(exp:ReaderExp, forThis:String, allowEmpty = true):Array<ReaderExp> {
        return Prelude.argList(exp, forThis, allowEmpty);
    }

    public static function bindingList(exp:ReaderExp, forThis:String, allowEmpty = false):Array<ReaderExp> {
        return Prelude.bindingList(exp, forThis, allowEmpty);
    }

    public static function compileTimeResolveToString(description:String, description2:String, exp:ReaderExp, k:KissState):String {
        switch (exp.def) {
            case StrExp(str):
                return str;
            case CallExp({pos: _, def: Symbol(mac)}, innerArgs) if (k.macros.exists(mac)):
                var docs = k.formDocs[mac];
                exp.checkNumArgs(docs.minArgs, docs.maxArgs, docs.expectedForm);
                return compileTimeResolveToString(description, description2, k.macros[mac](exp, innerArgs, k), k);
            default:
                throw KissError.fromExp(exp, '${description} should resolve at compile-time to a string literal of ${description2}');
        }
    }

    // Get the path to a haxelib the program depends on
    public static function libPath(haxelibName:String) {
        var classPaths = Context.getClassPath();
        classPaths.push(Path.normalize(Sys.getCwd()));

        for (dir in classPaths) {
            var parts = Path.normalize(dir).split("/");
            var matchingPartIndex = parts.indexOf(haxelibName);

            while (matchingPartIndex != -1) {
                var path = parts.slice(0, matchingPartIndex + 1).join("/");

                // TODO support all possible classPath formats:

                // <libname>/<classPath...>
                if (FileSystem.exists(Path.join([path, "haxelib.json"]))) return path;

                // <libname>/git/<classPath...>
                if (FileSystem.exists(Path.join([parts.slice(0, matchingPartIndex + 2).join("/"), "haxelib.json"]))) return path;

                // <libname>/<version>/haxelib/<classPath...>
                if (parts[matchingPartIndex + 2] == "haxelib") {
                    var haxelibPath = parts.slice(0, matchingPartIndex + 3).join("/");
                    if (FileSystem.exists(Path.join([haxelibPath, "haxelib.json"]))) return haxelibPath;
                }

                // <libname>/<version>/github/<commit>/<classPath...>
                if (parts[matchingPartIndex + 2] == "github") {
                    var githubPath = parts.slice(0, matchingPartIndex + 4).join("/");
                    if (FileSystem.exists(Path.join([githubPath, "haxelib.json"]))) return githubPath;
                }

                matchingPartIndex = parts.indexOf(haxelibName, matchingPartIndex + 1);
            }
        }

        // Special case fallback: kiss when its classpath is "src"
        if (haxelibName == "kiss") return Path.directory(Sys.getEnv("KISS_BUILD_HXML"));

        throw 'Could not find haxelib $haxelibName in class paths';
    }

    // Like haxe.macro.ExprTools.map() but for Kiss ReaderExps
    public static function expMap(exp:ReaderExp, func:ReaderExp->ReaderExp):ReaderExp {
        var result = switch (exp.def) {
            case CallExp(f, args):
                CallExp(func(f), Lambda.map(args, func));
            case ListExp(args):
                ListExp(Lambda.map(args, func));
            case BraceExp(args):
                BraceExp(Lambda.map(args, func));
            case TypedExp(type, exp):
                TypedExp(type, func(exp));
            case MetaExp(meta, exp):
                MetaExp(meta, func(exp));
            case FieldExp(field, exp, safeField):
                FieldExp(field, func(exp), safeField);
            case KeyValueExp(key, value):
                KeyValueExp(func(key), func(value));
            case Quasiquote(exp):
                Quasiquote(func(exp));
            case Unquote(exp):
                Unquote(func(exp));
            case UnquoteList(exp):
                UnquoteList(func(exp));
            case ListEatingExp(exps):
                ListEatingExp(Lambda.map(exps, func));
            case TypeParams(types):
                TypeParams(Lambda.map(types, func));
            case HaxeMeta(name, params, exp):
                var newParams = if (params != null) {
                    Lambda.map(params, func);
                } else {
                    null;
                }
                HaxeMeta(name, newParams, func(exp));
            case StrExp(_) | Symbol(_) | RawHaxe(_) | RawHaxeBlock(_) | ListRestExp(_) | None:
                exp.def;
        };
        return result.withPosOf(exp);
    }

    public static function expandTypeAliases(exp:ReaderExp, k:KissState) {
        return switch (exp.def) {
            case TypedExp(path, innerExp):
                TypedExp(replaceTypeAliases(path, k), innerExp).withPosOf(exp);
            default:
                expMap(exp, expandTypeAliases.bind(_, k));
        };
    }

    public static function expandTypeSymbol(exp:ReaderExp, k:KissState) {
        return switch (exp.def) {
            case Symbol(path):
                Symbol(replaceTypeAliases(path, k)).withPosOf(exp);
            default:
                exp;
        };
    }
}

#end