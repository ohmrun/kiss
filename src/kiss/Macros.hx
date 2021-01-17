package kiss;

import haxe.macro.Expr;
import haxe.macro.Context;
import uuid.Uuid;
import kiss.Reader;
import kiss.Kiss;
import kiss.CompileError;

using uuid.Uuid;
using kiss.Kiss;
using kiss.Reader;
using kiss.Helpers;

// Macros generate new Kiss reader expressions from the arguments of their call expression.
typedef MacroFunction = (wholeExp:ReaderExp, args:Array<ReaderExp>, k:KissState) -> Null<ReaderExp>;

class Macros {
    public static function builtins() {
        var macros:Map<String, MacroFunction> = [];

        function destructiveVersion(op:String, assignOp:String) {
            macros[assignOp] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k) -> {
                wholeExp.checkNumArgs(2, null, '($assignOp [var] [v1] [values...])');
                var b = wholeExp.expBuilder();
                b.call(
                    b.symbol("set"), [
                        exps[0],
                        b.call(
                            b.symbol(op),
                            exps)
                    ]);
            };
        }

        macros["%"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k) -> {
            wholeExp.checkNumArgs(2, 2, '(% [divisor] [dividend])');
            var b = wholeExp.expBuilder();
            b.opToDynamic(
                b.call(
                    b.symbol("Prelude.mod"), [
                        b.opFromDynamic(exps[1]),
                        b.opFromDynamic(exps[0])
                    ]));
        };

        destructiveVersion("%", "%=");

        macros["^"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k) -> {
            wholeExp.checkNumArgs(2, 2, '(^ [base] [exponent])');
            var b = wholeExp.expBuilder();
            b.opToDynamic(
                b.call(b.symbol("Prelude.pow"), [
                    b.opFromDynamic(exps[1]),
                    b.opFromDynamic(exps[0])
                ]));
        };
        destructiveVersion("^", "^=");

        macros["+"] = variadicMacro("Prelude.add");
        destructiveVersion("+", "+=");

        macros["-"] = variadicMacro("Prelude.subtract");
        destructiveVersion("-", "-=");

        macros["*"] = variadicMacro("Prelude.multiply");
        destructiveVersion("*", "*=");

        macros["/"] = variadicMacro("Prelude.divide");
        destructiveVersion("/", "/=");

        macros["min"] = variadicMacro("Prelude.min");
        macros["max"] = variadicMacro("Prelude.max");

        macros[">"] = variadicMacro("Prelude.greaterThan");
        macros[">="] = variadicMacro("Prelude.greaterEqual");
        macros["<"] = variadicMacro("Prelude.lessThan");
        macros["<="] = variadicMacro("Prelude.lesserEqual");

        macros["="] = variadicMacro("Prelude.areEqual");

        // the (apply [func] [args]) macro keeps its own list of aliases for the math operators
        // that can't just be function aliases because they emulate &rest behavior
        var opAliases = [
            "+" => "Prelude.add",
            "-" => "Prelude.subtract",
            "*" => "Prelude.multiply",
            "/" => "Prelude.divide",
            ">" => "Prelude.greaterThan",
            ">=" => "Prelude.greaterEqual",
            "<" => "Prelude.lessThan",
            "<=" => "Prelude.lesserEqual",
            "=" => "Prelude.areEqual",
            "max" => "Prelude.max",
            "min" => "Prelude.min"
        ];

        macros["apply"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k) -> {
            wholeExp.checkNumArgs(2, 2, '(apply [func] [argList])');
            var b = wholeExp.expBuilder();

            var callOn = switch (exps[0].def) {
                case FieldExp(field, exp):
                    exp;
                default:
                    b.symbol("null");
            };
            var func = switch (exps[0].def) {
                case Symbol(sym) if (opAliases.exists(sym)):
                    b.symbol(opAliases[sym]);
                default:
                    exps[0];
            };
            var args = switch (exps[0].def) {
                case Symbol(sym) if (opAliases.exists(sym)):
                    b.list([
                        b.call(
                            b.field("map", exps[1]), [
                                b.symbol("kiss.Operand.fromDynamic")
                            ])
                    ]);
                default:
                    exps[1];
            };
            b.call(
                b.symbol("Reflect.callMethod"), [
                    callOn, func, args
                ]);
        };

        macros["range"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k) -> {
            wholeExp.checkNumArgs(1, 3, '(range [?min] [max] [?step])');
            var b = wholeExp.expBuilder();
            var min = if (exps.length > 1) exps[0] else b.symbol("0");
            var max = if (exps.length > 1) exps[1] else exps[0];
            var step = if (exps.length > 2) exps[2] else b.symbol("1");
            b.call(
                b.symbol("Prelude.range"), [
                    min, max, step
                ]);
        };

        function bodyIf(formName:String, negated:Bool, wholeExp:ReaderExp, args:Array<ReaderExp>, k) {
            wholeExp.checkNumArgs(2, null, '($formName [condition] [body...])');
            var b = wholeExp.expBuilder();
            var condition = if (negated) {
                b.call(
                    b.symbol("not"), [
                        args[0]
                    ]);
            } else {
                args[0];
            }
            return b.call(b.symbol("if"), [
                condition,
                b.begin(args.slice(1))
            ]);
        }
        macros["when"] = bodyIf.bind("when", false);
        macros["unless"] = bodyIf.bind("unless", true);

        macros["cond"] = cond;

        // (or... ) uses (cond... ) under the hood
        macros["or"] = (wholeExp:ReaderExp, args:Array<ReaderExp>, k) -> {
            wholeExp.checkNumArgs(2, null, "(or [v1] [v2] [values...])");
            var b = wholeExp.expBuilder();
            var uniqueVarName = "_" + Uuid.v4().toShort();
            var uniqueVarSymbol = b.symbol(uniqueVarName);

            b.begin([
                b.call(b.symbol("deflocal"), [
                    b.meta("mut", b.typed("Dynamic", uniqueVarSymbol)),
                    b.symbol("null")
                ]),
                b.call(b.symbol("cond"), [
                    for (arg in args) {
                        b.call(
                            b.call(b.symbol("set"), [
                                uniqueVarSymbol,
                                arg
                            ]), [
                                uniqueVarSymbol
                            ]);
                    }
                ])
            ]);
        };

        // (and... uses (cond... ) and (not ...) under the hood)
        macros["and"] = (wholeExp:ReaderExp, args:Array<ReaderExp>, k) -> {
            wholeExp.checkNumArgs(2, null, "(and [v1] [v2] [values...])");
            var b = wholeExp.expBuilder();
            var uniqueVarName = "_" + Uuid.v4().toShort();
            var uniqueVarSymbol = b.symbol(uniqueVarName);

            var condCases = [
                for (arg in args) {
                    b.call(
                        b.call(
                            b.symbol("not"), [
                                b.call(
                                    b.symbol("set"), [uniqueVarSymbol, arg])
                            ]), [
                                b.symbol("null")
                            ]);
                }
            ];
            condCases.push(b.call(b.symbol("true"), [uniqueVarSymbol]));

            b.begin([
                b.call(
                    b.symbol("deflocal"), [
                        b.meta("mut", b.typed("Dynamic", uniqueVarSymbol)),
                        b.symbol("null")
                    ]),
                b.call(
                    b.symbol("cond"),
                    condCases)
            ]);
        };

        function arraySet(wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) {
            var b = wholeExp.expBuilder();
            return b.call(
                b.symbol("set"), [
                    b.call(b.symbol("nth"), [exps[0], exps[1]]),
                    exps[2]
                ]);
        }
        macros["setNth"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(3, 3, "(setNth [list] [index] [value])");
            arraySet(wholeExp, exps, k);
        };
        macros["dictSet"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(3, 3, "(dictSet [dict] [key] [value])");
            arraySet(wholeExp, exps, k);
        };

        // TODO use expBuilder()
        macros["assert"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(1, 2, "(assert [expression] [message])");
            var expression = exps[0];
            var basicMessage = 'Assertion ${expression.def.toString()} failed';
            var messageExp = if (exps.length > 1) {
                CallExp(Symbol("+").withPosOf(wholeExp), [StrExp(basicMessage + ": ").withPosOf(wholeExp), exps[1]]);
            } else {
                StrExp(basicMessage);
            };
            CallExp(Symbol("unless").withPosOf(wholeExp), [
                expression,
                CallExp(Symbol("throw").withPosOf(wholeExp), [messageExp.withPosOf(wholeExp)]).withPosOf(wholeExp)
            ]).withPosOf(wholeExp);
        };

        function stringsThatMatch(exp:ReaderExp) {
            return switch (exp.def) {
                case StrExp(s):
                    [s];
                case ListExp(strings):
                    [
                        for (s in strings)
                            switch (s.def) {
                                case StrExp(s):
                                    s;
                                default:
                                    throw CompileError.fromExp(s, 'initiator list of defreadermacro must only contain strings');
                            }
                    ];
                default:
                    throw CompileError.fromExp(exp, 'first argument to defreadermacro should be a String or list of strings');
            };
        }

        macros["defmacro"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(3, null, '(defmacro [name] [[args...]] [body...])');

            var table = k.macros;

            var name = switch (exps[0].def) {
                case Symbol(name): name;
                default: throw CompileError.fromExp(exps[0], "macro name should be a symbol");
            };

            var argList = switch (exps[1].def) {
                case ListExp(macroArgs): macroArgs;
                case CallExp(_, _):
                    throw CompileError.fromExp(exps[1], 'expected a macro argument list. Change the parens () to brackets []');
                default:
                    throw CompileError.fromExp(exps[1], 'expected a macro argument list');
            };

            // This is similar to &opt and &rest processing done by Helpers.makeFunction()
            // but combining them would probably make things less readable and harder
            // to maintain, because defmacro makes an actual function, not a function definition
            var minArgs = 0;
            var maxArgs = 0;
            // Once the &opt meta appears, all following arguments are optional until &rest
            var optIndex = -1;
            // Once the &rest meta appears, no other arguments can be declared
            var restIndex = -1;
            var argNames = [];

            var macroCallForm = '($name';

            for (arg in argList) {
                if (restIndex != -1) {
                    throw CompileError.fromExp(arg, "macros cannot declare arguments after a &rest argument");
                }
                switch (arg.def) {
                    case Symbol(name):
                        argNames.push(name);
                        if (optIndex == -1) {
                            ++minArgs;
                            macroCallForm += ' [$name]';
                        } else {
                            macroCallForm += ' [?$name]';
                        }
                        ++maxArgs;
                    case MetaExp("opt", {pos: _, def: Symbol(name)}):
                        argNames.push(name);
                        macroCallForm += ' [?$name]';
                        optIndex = maxArgs;
                        ++maxArgs;
                    case MetaExp("rest", {pos: _, def: Symbol(name)}):
                        argNames.push(name);
                        macroCallForm += ' [$name...]';
                        restIndex = maxArgs;
                        maxArgs = null;
                    default:
                        throw CompileError.fromExp(arg, "macro argument should be an untyped symbol or a symbol annotated with &opt or &rest");
                }
            }

            macroCallForm += ')';
            if (optIndex == -1)
                optIndex = minArgs;
            if (restIndex == -1)
                restIndex = optIndex;

            macros[name] = (wholeExp:ReaderExp, innerExps:Array<ReaderExp>, k:KissState) -> {
                wholeExp.checkNumArgs(minArgs, maxArgs, macroCallForm);
                var innerArgNames = argNames.copy();

                var args:Map<String, Dynamic> = [];
                for (idx in 0...optIndex) {
                    args[innerArgNames.shift()] = innerExps[idx];
                }
                for (idx in optIndex...restIndex) {
                    args[innerArgNames.shift()] = if (exps.length > idx) innerExps[idx] else null;
                }
                if (innerArgNames.length > 0)
                    args[innerArgNames.shift()] = innerExps.slice(restIndex);

                // Return the macro expansion:
                var expDef:ReaderExpDef = Helpers.runAtCompileTime(CallExp(Symbol("begin").withPosOf(wholeExp), exps.slice(2)).withPosOf(wholeExp), k, args);
                expDef.withPosOf(wholeExp);
            };

            null;
        };

        macros["defreadermacro"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(3, null, '(defreadermacro ["[startingString]" or [startingStrings...]] [[streamArgName]] [body...])');

            // reader macros declared in the form (defreadermacro &start ...) will only be applied
            // at the beginning of lines
            var table = k.readTable;

            // reader macros can define a list of strings that will trigger the macro. When there are multiple,
            // the macro will put back the initiating string into the stream so you can check which one it was
            var strings = switch (exps[0].def) {
                case MetaExp("start", stringsExp):
                    table = k.startOfLineReadTable;
                    stringsThatMatch(stringsExp);
                default:
                    stringsThatMatch(exps[0]);
            };
            for (s in strings) {
                switch (exps[1].def) {
                    case ListExp([{pos: _, def: Symbol(streamArgName)}]):
                        table[s] = (stream, k) -> {
                            if (strings.length > 1) {
                                stream.putBackString(s);
                            }
                            var body = CallExp(Symbol("begin").withPos(stream.position()), exps.slice(2)).withPos(stream.position());
                            Helpers.runAtCompileTime(body, k, [streamArgName => stream]);
                        };
                    case CallExp(_, []):
                        throw CompileError.fromExp(exps[1], 'expected an argument list. Change the parens () to brackets []');
                    default:
                        throw CompileError.fromExp(exps[1], 'second argument to defreadermacro should be [steamArgName]');
                }
            }

            return null;
        };

        macros["defalias"] = (wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) -> {
            wholeExp.checkNumArgs(2, 2, "(defalias [[&call or &ident] whenItsThis] [makeItThis])");
            var aliasMap:Map<String, ReaderExpDef> = null;
            var nameExp = switch (exps[0].def) {
                case MetaExp("call", nameExp):
                    aliasMap = k.callAliases;
                    nameExp;
                case MetaExp("ident", nameExp):
                    aliasMap = k.identAliases;
                    nameExp;
                default:
                    throw CompileError.fromExp(exps[0], 'first argument to defalias should be a symbol for the alias annotated with either &call or &ident');
            };
            var name = switch (nameExp.def) {
                case Symbol(whenItsThis):
                    whenItsThis;
                default:
                    throw CompileError.fromExp(exps[0], 'first argument to defalias should be a symbol for the alias annotated with either &call or &ident');
            };
            aliasMap[name] = exps[1].def;
            return null;
        };

        // Macros that null-check and extract patterns from enums (inspired by Rust)
        function ifLet(wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) {
            wholeExp.checkNumArgs(2, null, "(ifLet [[enum bindings...]] [thenExp] [?elseExp])");
            var b = wholeExp.expBuilder();

            var thenExp = exps[1];
            var elseExp = if (exps.length > 2) {
                exps[2];
            } else {
                b.symbol("null");
            };

            var bindingList = exps[0].bindingList("ifLet");
            var firstPattern = bindingList.shift();
            var firstValue = bindingList.shift();

            return b.call(
                b.symbol("if"), [
                    firstValue,
                    b.call(
                        b.symbol("case"), [
                            firstValue,
                            b.call(
                                firstPattern, [
                                    if (bindingList.length == 0) {
                                        exps[1];
                                    } else {
                                        ifLet(wholeExp, [
                                            b.list(bindingList)
                                        ].concat(exps.slice(1)), k);
                                    }
                                ]),
                            b.call(
                                b.symbol("otherwise"), [
                                    elseExp
                                ])
                        ]),
                    elseExp
                ]);
        }

        macros["ifLet"] = ifLet;

        // TODO whenLet
        // wholeExp.checkNumArgs(2, null, "(whenLet [[enum bindings...]] [body...])");
        // TODO unlessLet
        // wholeExp.checkNumArgs(2, null, "(unlessLet [[enum bindings...]] [body...])");

        // TODO use expBuilder()
        function awaitLet(wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) {
            wholeExp.checkNumArgs(2, null, "(awaitLet [[promise bindings...]] [body...])");
            var bindingList = exps[0].bindingList("awaitLet");
            var firstName = bindingList.shift();
            var firstValue = bindingList.shift();
            return CallExp(FieldExp("then", firstValue).withPosOf(wholeExp), [
                CallExp(Symbol("lambda").withPosOf(wholeExp), [
                    ListExp([firstName]).withPosOf(wholeExp),
                    if (bindingList.length == 0) {
                        CallExp(Symbol("begin").withPosOf(wholeExp), exps.slice(1)).withPosOf(wholeExp);
                    } else {
                        awaitLet(wholeExp, [ListExp(bindingList).withPosOf(wholeExp)].concat(exps.slice(1)), k);
                    }
                ]).withPosOf(wholeExp),
                // Handle rejections:
                CallExp(Symbol("lambda").withPosOf(wholeExp), [
                    ListExp([Symbol("reason").withPosOf(wholeExp)]).withPosOf(wholeExp),
                    CallExp(Symbol("throw").withPosOf(wholeExp), [
                        // TODO generalize CompileError to KissError which will also handle runtime errors
                        // with the same source position format
                        StrExp("rejected promise").withPosOf(wholeExp)
                    ]).withPosOf(wholeExp)
                ]).withPosOf(wholeExp)
            ]).withPosOf(wholeExp);
        }

        macros["awaitLet"] = awaitLet;

        return macros;
    }

    // TODO use expBuilder()
    // cond expands telescopically into a nested if expression
    static function cond(wholeExp:ReaderExp, exps:Array<ReaderExp>, k:KissState) {
        wholeExp.checkNumArgs(1, null, "(cond [cases...])");
        return switch (exps[0].def) {
            case CallExp(condition, body):
                CallExp(Symbol("if").withPosOf(wholeExp), [
                    condition,
                    CallExp(Symbol("begin").withPosOf(wholeExp), body).withPosOf(wholeExp),
                    if (exps.length > 1) {
                        cond(CallExp(Symbol("cond").withPosOf(wholeExp), exps.slice(1)).withPosOf(wholeExp), exps.slice(1), k);
                    } else {
                        Symbol("null").withPosOf(wholeExp);
                    }
                ]).withPosOf(wholeExp);
            default:
                throw CompileError.fromExp(exps[0], 'top-level expression of (cond... ) must be a call list starting with a condition expression');
        };
    }

    // TODO use expBuilder()
    static function variadicMacro(func:String):MacroFunction {
        return (wholeExp:ReaderExp, exps:Array<ReaderExp>, k) -> {
            CallExp(Symbol(func).withPosOf(wholeExp), [
                ListExp([
                    for (exp in exps) {
                        CallExp(Symbol("kiss.Operand.fromDynamic").withPosOf(wholeExp), [exp]).withPosOf(wholeExp);
                    }
                ]).withPosOf(wholeExp)
            ]).withPosOf(wholeExp);
        };
    }
}
