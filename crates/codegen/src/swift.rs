use super::code_indenter::{CodeIndenter, Indenter};
use super::util::{
    collect_case, is_reducer_invokable, iter_procedures, iter_reducers, iter_table_names_and_types,
    print_auto_generated_file_comment, print_auto_generated_version_comment, type_ref_name,
};
use super::Lang;
use crate::{CodegenOptions, OutputFile};

use std::ops::Deref;

use convert_case::{Case, Casing};
use spacetimedb_lib::sats::layout::PrimitiveType;
use spacetimedb_schema::def::{ModuleDef, ProcedureDef, ReducerDef, TableDef, TypeDef};
use spacetimedb_schema::identifier::Identifier;
use spacetimedb_schema::schema::TableSchema;
use spacetimedb_schema::type_for_generate::{AlgebraicTypeDef, AlgebraicTypeUse};

const INDENT: &str = "    ";

pub struct Swift;

impl Lang for Swift {
    fn generate_type_files(&self, module: &ModuleDef, typ: &TypeDef) -> Vec<OutputFile> {
        let type_name = collect_case(Case::Pascal, typ.accessor_name.name_segments());

        let mut output = CodeIndenter::new(String::new(), INDENT);
        let out = &mut output;

        print_auto_generated_file_comment(out);
        writeln!(out);

        let typespace = module.typespace_for_generate();

        match &typespace[typ.ty] {
            AlgebraicTypeDef::Product(product) => {
                let needs_foundation = product.elements.iter().any(|(_, ty)| type_needs_foundation(ty));
                if needs_foundation {
                    writeln!(out, "import Foundation");
                }
                writeln!(out, "import SpacetimeDBSwift");
                writeln!(out);
                define_struct_for_product(module, out, &type_name, &product.elements);
            }
            AlgebraicTypeDef::PlainEnum(plain_enum) => {
                writeln!(out, "import SpacetimeDBSwift");
                writeln!(out);
                define_plain_enum(out, &type_name, &plain_enum.variants);
            }
            AlgebraicTypeDef::Sum(sum) => {
                let needs_foundation = sum.variants.iter().any(|(_, ty)| type_needs_foundation(ty));
                if needs_foundation {
                    writeln!(out, "import Foundation");
                }
                writeln!(out, "import SpacetimeDBSwift");
                writeln!(out);
                define_tagged_enum(module, out, &type_name, &sum.variants);
            }
        }

        let filename = collect_case(Case::Snake, typ.accessor_name.name_segments()) + "_type.swift";
        vec![OutputFile {
            filename,
            code: output.into_inner(),
        }]
    }

    fn generate_table_file_from_schema(
        &self,
        module: &ModuleDef,
        table: &TableDef,
        schema: TableSchema,
    ) -> OutputFile {
        let mut output = CodeIndenter::new(String::new(), INDENT);
        let out = &mut output;

        print_auto_generated_file_comment(out);
        writeln!(out);
        writeln!(out, "import SpacetimeDBSwift");
        writeln!(out);

        let type_name = table.accessor_name.deref().to_case(Case::Pascal);

        // Find primary key field name
        let primary_key_field = table.primary_key.map(|pk| {
            let product_def = module.typespace_for_generate()[table.product_type_ref]
                .as_product()
                .unwrap();
            let (field_name, _) = &product_def.elements[pk.idx()];
            field_name.deref().to_case(Case::Camel)
        });

        writeln!(out, "extension {type_name}: SpacetimeDBTable {{");
        {
            out.indent(1);
            writeln!(
                out,
                "public static var tableName: String {{ \"{}\" }}",
                table.name.deref()
            );
            match &primary_key_field {
                Some(pk) => writeln!(out, "public static var primaryKey: String? {{ \"{pk}\" }}"),
                None => writeln!(out, "public static var primaryKey: String? {{ nil }}"),
            }

            // Expose unique columns
            let constraints = schema.backcompat_column_constraints();
            let product_def = module.typespace_for_generate()[table.product_type_ref]
                .as_product()
                .unwrap();
            let unique_fields: Vec<String> = schema
                .columns()
                .iter()
                .filter(|col| {
                    use spacetimedb_primitives::ColList;
                    constraints[&ColList::from(col.col_pos)].has_unique()
                })
                .map(|col| {
                    let (field_name, _) = &product_def.elements[col.col_pos.idx()];
                    field_name.deref().to_case(Case::Camel)
                })
                .collect();

            if !unique_fields.is_empty() {
                write!(out, "public static var uniqueColumns: [String] {{ [");
                for (i, field) in unique_fields.iter().enumerate() {
                    if i > 0 {
                        write!(out, ", ");
                    }
                    write!(out, "\"{field}\"");
                }
                writeln!(out, "] }}");
            }
            out.dedent(1);
        }
        writeln!(out, "}}");

        let filename = table.accessor_name.deref().to_case(Case::Snake) + "_table.swift";
        OutputFile {
            filename,
            code: output.into_inner(),
        }
    }

    fn generate_reducer_file(&self, module: &ModuleDef, reducer: &ReducerDef) -> OutputFile {
        let mut output = CodeIndenter::new(String::new(), INDENT);
        let out = &mut output;

        print_auto_generated_file_comment(out);
        writeln!(out);

        let needs_foundation = reducer
            .params_for_generate
            .elements
            .iter()
            .any(|(_, ty)| type_needs_foundation(ty));
        if needs_foundation {
            writeln!(out, "import Foundation");
        }
        writeln!(out, "import SpacetimeDBSwift");
        writeln!(out);

        let reducer_name = reducer.accessor_name.deref().to_case(Case::Pascal);
        define_struct_for_product(module, out, &format!("{reducer_name}Args"), &reducer.params_for_generate.elements);

        let filename = reducer.accessor_name.deref().to_case(Case::Snake) + "_reducer.swift";
        OutputFile {
            filename,
            code: output.into_inner(),
        }
    }

    fn generate_procedure_file(&self, module: &ModuleDef, procedure: &ProcedureDef) -> OutputFile {
        let mut output = CodeIndenter::new(String::new(), INDENT);
        let out = &mut output;

        print_auto_generated_file_comment(out);
        writeln!(out);

        let needs_foundation = procedure
            .params_for_generate
            .elements
            .iter()
            .any(|(_, ty)| type_needs_foundation(ty))
            || type_needs_foundation(&procedure.return_type_for_generate);
        if needs_foundation {
            writeln!(out, "import Foundation");
        }
        writeln!(out, "import SpacetimeDBSwift");
        writeln!(out);

        let procedure_name = procedure.accessor_name.deref().to_case(Case::Pascal);

        // Generate args struct
        define_struct_for_product(
            module,
            out,
            &format!("{procedure_name}Args"),
            &procedure.params_for_generate.elements,
        );

        // Generate return type alias
        writeln!(out);
        let mut ret_type = String::new();
        write_type(module, &mut ret_type, &procedure.return_type_for_generate);
        writeln!(out, "public typealias {procedure_name}Result = {ret_type}");

        let filename = procedure.accessor_name.deref().to_case(Case::Snake) + "_procedure.swift";
        OutputFile {
            filename,
            code: output.into_inner(),
        }
    }

    fn generate_global_files(&self, module: &ModuleDef, options: &CodegenOptions) -> Vec<OutputFile> {
        let mut output = CodeIndenter::new(String::new(), INDENT);
        let out = &mut output;

        print_auto_generated_file_comment(out);
        print_auto_generated_version_comment(out);
        writeln!(out, "import SpacetimeDBSwift");
        writeln!(out);

        // Reducer enum
        writeln!(out, "public enum Reducer: String, CaseIterable, Sendable {{");
        out.indent(1);
        for reducer in iter_reducers(module, options.visibility) {
            if !is_reducer_invokable(reducer) {
                continue;
            }
            let case_name = reducer.accessor_name.deref().to_case(Case::Camel);
            writeln!(out, "case {case_name} = \"{}\"", reducer.name.deref());
        }
        out.dedent(1);
        writeln!(out, "}}");
        writeln!(out);

        // Table enum
        writeln!(out, "public enum Table: String, CaseIterable, Sendable {{");
        out.indent(1);
        for (name, accessor_name, _) in iter_table_names_and_types(module, options.visibility) {
            let case_name = accessor_name.deref().to_case(Case::Camel);
            writeln!(out, "case {case_name} = \"{}\"", name.deref());
        }
        out.dedent(1);
        writeln!(out, "}}");
        writeln!(out);

        // Procedure enum
        let procedures: Vec<_> = iter_procedures(module, options.visibility).collect();
        if !procedures.is_empty() {
            writeln!(out, "public enum Procedure: String, CaseIterable, Sendable {{");
            out.indent(1);
            for procedure in &procedures {
                let case_name = procedure.accessor_name.deref().to_case(Case::Camel);
                writeln!(out, "case {case_name} = \"{}\"", procedure.name.deref());
            }
            out.dedent(1);
            writeln!(out, "}}");
        }

        let filename = "module.swift".to_string();
        vec![OutputFile {
            filename,
            code: output.into_inner(),
        }]
    }
}

/// Check if a type requires `import Foundation`.
fn type_needs_foundation(ty: &AlgebraicTypeUse) -> bool {
    match ty {
        AlgebraicTypeUse::Uuid => true,
        AlgebraicTypeUse::Array(inner) => {
            matches!(&**inner, AlgebraicTypeUse::Primitive(PrimitiveType::U8)) || type_needs_foundation(inner)
        }
        AlgebraicTypeUse::Option(inner) => type_needs_foundation(inner),
        AlgebraicTypeUse::Result { ok_ty, err_ty } => {
            type_needs_foundation(ok_ty) || type_needs_foundation(err_ty)
        }
        _ => false,
    }
}

/// Write a Swift type name for the given algebraic type.
fn write_type(module: &ModuleDef, out: &mut String, ty: &AlgebraicTypeUse) {
    match ty {
        AlgebraicTypeUse::Unit => out.push_str("Void"),
        AlgebraicTypeUse::Never => out.push_str("Never"),
        AlgebraicTypeUse::Identity => out.push_str("Identity"),
        AlgebraicTypeUse::ConnectionId => out.push_str("ConnectionId"),
        AlgebraicTypeUse::Timestamp => out.push_str("Timestamp"),
        AlgebraicTypeUse::TimeDuration => out.push_str("TimeDuration"),
        AlgebraicTypeUse::ScheduleAt => out.push_str("ScheduleAt"),
        AlgebraicTypeUse::Uuid => out.push_str("Foundation.UUID"),
        AlgebraicTypeUse::String => out.push_str("String"),
        AlgebraicTypeUse::Primitive(prim) => match prim {
            PrimitiveType::Bool => out.push_str("Bool"),
            PrimitiveType::I8 => out.push_str("Int8"),
            PrimitiveType::U8 => out.push_str("UInt8"),
            PrimitiveType::I16 => out.push_str("Int16"),
            PrimitiveType::U16 => out.push_str("UInt16"),
            PrimitiveType::I32 => out.push_str("Int32"),
            PrimitiveType::U32 => out.push_str("UInt32"),
            PrimitiveType::I64 => out.push_str("Int64"),
            PrimitiveType::U64 => out.push_str("UInt64"),
            PrimitiveType::I128 => out.push_str("Int128"),
            PrimitiveType::U128 => out.push_str("UInt128"),
            PrimitiveType::I256 => out.push_str("SpacetimeDB.I256"),
            PrimitiveType::U256 => out.push_str("SpacetimeDB.U256"),
            PrimitiveType::F32 => out.push_str("Float"),
            PrimitiveType::F64 => out.push_str("Double"),
        },
        AlgebraicTypeUse::Array(elem_ty) => {
            if matches!(&**elem_ty, AlgebraicTypeUse::Primitive(PrimitiveType::U8)) {
                out.push_str("Data");
            } else {
                out.push('[');
                write_type(module, out, elem_ty);
                out.push(']');
            }
        }
        AlgebraicTypeUse::Option(inner_ty) => {
            write_type(module, out, inner_ty);
            out.push('?');
        }
        AlgebraicTypeUse::Result { ok_ty, err_ty } => {
            out.push_str("Result<");
            write_type(module, out, ok_ty);
            out.push_str(", ");
            write_type(module, out, err_ty);
            out.push('>');
        }
        AlgebraicTypeUse::Ref(r) => {
            out.push_str(&type_ref_name(module, *r));
        }
    }
}

fn define_struct_for_product(
    module: &ModuleDef,
    out: &mut Indenter,
    name: &str,
    elements: &[(Identifier, AlgebraicTypeUse)],
) {
    if elements.is_empty() {
        writeln!(out, "public struct {name}: Codable, Equatable, Sendable {{}}");
        return;
    }

    writeln!(out, "public struct {name}: Codable, Equatable, Sendable {{");
    out.indent(1);

    // Properties
    for (field_ident, field_ty) in elements {
        let field_name = field_ident.deref().to_case(Case::Camel);
        let mut swift_type = String::new();
        write_type(module, &mut swift_type, field_ty);
        writeln!(out, "public var {field_name}: {swift_type}");
    }

    writeln!(out);

    // Memberwise init
    write!(out, "public init(");
    for (i, (field_ident, field_ty)) in elements.iter().enumerate() {
        if i > 0 {
            write!(out, ", ");
        }
        let field_name = field_ident.deref().to_case(Case::Camel);
        let mut swift_type = String::new();
        write_type(module, &mut swift_type, field_ty);
        write!(out, "{field_name}: {swift_type}");
    }
    writeln!(out, ") {{");
    out.indent(1);
    for (field_ident, _) in elements {
        let field_name = field_ident.deref().to_case(Case::Camel);
        writeln!(out, "self.{field_name} = {field_name}");
    }
    out.dedent(1);
    writeln!(out, "}}");

    // CodingKeys if any field name differs from original
    let needs_coding_keys = elements
        .iter()
        .any(|(ident, _)| ident.deref().to_case(Case::Camel) != *ident.deref());
    if needs_coding_keys {
        writeln!(out);
        writeln!(out, "enum CodingKeys: String, CodingKey {{");
        out.indent(1);
        for (field_ident, _) in elements {
            let camel = field_ident.deref().to_case(Case::Camel);
            let original = field_ident.deref();
            if camel != *original {
                writeln!(out, "case {camel} = \"{original}\"");
            } else {
                writeln!(out, "case {camel}");
            }
        }
        out.dedent(1);
        writeln!(out, "}}");
    }

    out.dedent(1);
    writeln!(out, "}}");
}

fn define_plain_enum(out: &mut Indenter, name: &str, variants: &[Identifier]) {
    writeln!(
        out,
        "public enum {name}: String, Codable, Equatable, Sendable, CaseIterable {{"
    );
    out.indent(1);
    for variant in variants {
        let case_name = variant.deref().to_case(Case::Camel);
        let original = variant.deref();
        if case_name != *original {
            writeln!(out, "case {case_name} = \"{original}\"");
        } else {
            writeln!(out, "case {case_name}");
        }
    }
    out.dedent(1);
    writeln!(out, "}}");
}

fn define_tagged_enum(
    module: &ModuleDef,
    out: &mut Indenter,
    name: &str,
    variants: &[(Identifier, AlgebraicTypeUse)],
) {
    writeln!(out, "public enum {name}: Codable, Equatable, Sendable {{");
    out.indent(1);
    for (variant_ident, variant_ty) in variants {
        let case_name = variant_ident.deref().to_case(Case::Camel);
        if matches!(variant_ty, AlgebraicTypeUse::Unit) {
            writeln!(out, "case {case_name}");
        } else {
            let mut swift_type = String::new();
            write_type(module, &mut swift_type, variant_ty);
            writeln!(out, "case {case_name}({swift_type})");
        }
    }
    out.dedent(1);
    writeln!(out, "}}");
}
