package monoexport;

import haxe.macro.Type;

class MonoExport
{
	macro public static function init ()
	{
		haxe.macro.Context.onGenerate(export);
		return null;
	}

	public static function subType (t:Type) : Type
	{
		return switch (t)
		{
			case TInst(_, p): p[0];
			default: null;
		}
	}

	public static function arrayType (s:String) : String
	{
		return switch (s) {
			case "std::string": "String";
			case "double": "Float";
			case "int": "Int";
			case "bool": "Bool";
			default: "";
		}
	}

	public static function toCppType (t:Type, typeLess=false) : String
	{
		if (t == null)
		{
			trace("got null t");
			return "void";
		}

		return switch (t)
		{
			case TAbstract(_.get() => t, p):
				switch (t.name)
				{
					case "Int": "int";
					case "Void": "void";
					case "Bool": "bool";
					case "Float": "double";

					default:
						trace("Unknown abstract: " + t.name);
						"void";
				}

			case TInst(_.get() => t, p):
				switch (t.name)
				{
					case "String": "std::string";
					case "Array": typeLess ? "std::vector" : "std::vector<" + toCppType(p[0]) + ">";

					default:
						trace("Unknown inst: " + t.name);
						"void";
				}

			default:
				trace("Unknown type: " + t);
				"void";
		}
	}

	public static function monoClass (t:String) : String
	{
		return switch (t) {
			case "int": "int32";
			case "std::string": "string";
			case "bool": "boolean";
			case "double": "double";
			default: trace("unknown mono class " + t); "void";
		}
	}

	public static function export (types:Array<Type>)
	{
		var out = haxe.macro.Compiler.getDefine("monoexport-out");
		if (out == null)
		{
			out = "MonoExport.hpp";
		}

		var types = types.map(function (t) return switch (t) {
			case TInst(_.get() => t, p):
				var ss = t.statics.get().filter(function (s) return switch (s.kind) {
					case FMethod(_): true;
					case FVar(_, _): false;
				});

				if (p.length == 0 && t.meta.has(":monoExport") && ss.length > 0)
					{ t: t, ss: ss };
				else
					null;

			default:
				null;
		});
		types = types.filter(function (t) return t != null);

		var o = sys.io.File.write(out, false);
		o.writeString("#pragma once

#include <mono/jit/jit.h>
#include <mono/metadata/assembly.h>
#include <vector>
#include <string>

/* Autogenerated */

namespace MonoExport
{
	MonoDomain* domain;
	MonoImage* image;

	namespace MonoExportUtils
	{
		MonoClass* cls;
");

		for (t in ["String", "Int", "Float", "Bool"])
		{
			o.writeString("\n\t\tMonoObject* toArray" + t + " (MonoArray* a)\n\t\t{\n");
			o.writeString("\t\t\tMonoMethod* method = mono_class_get_method_from_name(cls, \"toArray" + t + "\", 1);\n");
			o.writeString("\t\t\tvoid* args[1];\n\t\t\targs[0] = a;\n");
			o.writeString("\t\t\treturn mono_runtime_invoke(method, NULL, args, NULL);\n");
			o.writeString("\t\t}\n\n");

			o.writeString("\t\tMonoArray* fromArray" + t + " (MonoObject* a)\n\t\t{\n");
			o.writeString("\t\t\tMonoMethod* method = mono_class_get_method_from_name(cls, \"fromArray" + t + "\", 1);\n");
			o.writeString("\t\t\tvoid* args[1];\n\t\t\targs[0] = a;\n");
			o.writeString("\t\t\treturn (MonoArray*)mono_runtime_invoke(method, NULL, args, NULL);\n");
			o.writeString("\t\t}\n");
		}

		o.writeString("\t}\n\n");

		for (t in types)
		{
			o.writeString("\tnamespace " + t.t.name + "\n\t{");
			o.writeString("\n\t\tMonoClass* cls;\n");

			var ss = t.ss.map(function (s) return switch (s.type) {
				case TFun(a, r):
					{ s: s, a: a, r: r };
				default:
					null;
			}).filter(function (s) return s != null);

			for (s in ss)
			{
				var nbArg = s.a.length;
				var r = toCppType(s.r);
				var rr = toCppType(s.r, true);

				o.writeString("\n\t\t" + r + " " + s.s.name + " (");

				var args = [];
				for (a in s.a)
				{
					args.push(toCppType(a.t) + " " + a.name);
				}
				o.writeString(args.join(", "));

				o.writeString(")\n\t\t{\n");

				for (a in 0...s.a.length)
				{
					switch (toCppType(s.a[a].t, true))
					{
						case "std::vector":
							var sub = toCppType(subType(s.a[a].t));
							var msub = monoClass(sub);
							var nsub = msub == "string" ? "MonoString*" : sub;
							var name = s.a[a].name;
							var elem = name + ".at(i)";
							if (msub == "string") elem = "mono_string_new(domain, " + elem + ".c_str())";

							o.writeString("\t\t\tMonoArray* " + name +  "__array = mono_array_new(domain, mono_get_" + msub + "_class(), " + name + ".size());\n");
							o.writeString("\t\t\tfor (int i = 0 ; i < " + name + ".size() ; i++)\n\t\t\t{\n");
							o.writeString("\t\t\t\tmono_array_set(" + name + "__array, " + nsub + ", i, " + elem + ");\n\t\t\t}\n");

						default:
					}
				}

				o.writeString("\t\t\tMonoMethod* method = mono_class_get_method_from_name(cls, \"" + s.s.name + "\", " + nbArg + ");\n");
				o.writeString("\t\t\tvoid* args[" + nbArg + "];\n");

				for (a in 0...s.a.length)
				{
					var value = s.a[a].name;

					switch (toCppType(s.a[a].t, true))
					{
						case "std::string":
							value = "mono_string_new(domain, " + value + ".c_str())";

						case "std::vector":
							var sub = toCppType(subType(s.a[a].t));
							value = "MonoExport::MonoExportUtils::toArray" + arrayType(sub) + "(" + value + "__array)";

						default:
							value = "&" + value;
					}

					o.writeString("\t\t\targs[" + a + "] = " + value + ";\n");
				}

				o.writeString("\t\t\tMonoObject* r = mono_runtime_invoke(method, NULL, args, NULL);\n");

				switch (rr)
				{
					case "void": // do nothing

					case "std::string":
						o.writeString("\t\t\tchar* c = mono_string_to_utf8((MonoString*)r);\n");
						o.writeString("\t\t\tstd::string rs(c);\n");
						o.writeString("\t\t\tmono_free(c);\n");
						o.writeString("\t\t\treturn rs;\n");

					case "std::vector":
						var sub = toCppType(subType(s.r));

						o.writeString("\t\t\tMonoArray* rr = MonoExport::MonoExportUtils::fromArray" + arrayType(sub) + "(r);\n");
						o.writeString("\t\t\t" + r + " r__array;\n");
						o.writeString("\t\t\tfor (int i = 0 ; i < mono_array_length(rr) ; i++)\n\t\t\t{\n");

						if (sub == "std::string")
						{
							o.writeString("\t\t\t\tchar* c = mono_string_to_utf8(mono_array_get(rr, MonoString*, i));\n");
							o.writeString("\t\t\t\tstd::string tmp(c);\n");
							o.writeString("\t\t\t\tmono_free(c);\n");
						}
						else
						{
							o.writeString("\t\t\t\t" + sub + " tmp = mono_array_get(rr, " + sub + ", i);\n");
						}

						o.writeString("\t\t\t\tr__array.push_back(tmp);\n\t\t\t}\n");
						o.writeString("\t\t\treturn r__array;\n");

					default:
						o.writeString("\t\t\treturn *(" + r + "*)mono_object_unbox (r);\n");
				}

				o.writeString("\t\t}\n");
			}

			o.writeString("\t}\n");
		}

		o.writeString("\n\tvoid init (const char* file)
	{
		domain = mono_jit_init(file);
		MonoAssembly* assembly = mono_domain_assembly_open(domain, file);
		image = mono_assembly_get_image(assembly);

");

		for (t in types)
		{
			o.writeString("\t\t" + t.t.name + "::cls = mono_class_from_name(image, \"\", \"" + t.t.name + "\");\n");
		}

		o.writeString("\t\tMonoExportUtils::cls = mono_class_from_name(image, \"monoexport\", \"MonoExportUtils\");\n");

		o.writeString("\t\tMonoClass* boot = mono_class_from_name(image, \"cs\", \"Boot\");
		MonoMethod* method = mono_class_get_method_from_name(boot, \"init\", 0);
		void* args[0];
		MonoObject* r = mono_runtime_invoke(method, NULL, args, NULL);
	}

	void clean ()
	{
		mono_jit_cleanup(domain);
	}
}
");

		o.flush();
		o.close();
	}
}
