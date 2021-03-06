// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
library kernel.clone;

import 'ast.dart';
import 'type_algebra.dart';

/// Visitor that return a clone of a tree, maintaining references to cloned
/// objects.
///
/// It is safe to clone members, but cloning a class or library is not
/// supported.
class CloneVisitor extends TreeVisitor {
  final Map<VariableDeclaration, VariableDeclaration> variables =
      <VariableDeclaration, VariableDeclaration>{};
  final Map<LabeledStatement, LabeledStatement> labels =
      <LabeledStatement, LabeledStatement>{};
  final Map<SwitchCase, SwitchCase> switchCases = <SwitchCase, SwitchCase>{};
  final Map<TypeParameter, DartType> typeSubstitution;

  CloneVisitor({Map<TypeParameter, DartType> typeSubstitution})
      : this.typeSubstitution = ensureMutable(typeSubstitution);

  static Map<TypeParameter, DartType> ensureMutable(
      Map<TypeParameter, DartType> map) {
    // We need to mutate this map, so make sure we don't use a constant map.
    if (map == null || map.isEmpty) {
      return <TypeParameter, DartType>{};
    }
    return map;
  }

  TreeNode visitLibrary(Library node) {
    throw 'Cloning of libraries is not implemented';
  }

  TreeNode visitClass(Class node) {
    throw 'Cloning of classes is not implemented';
  }

  TreeNode clone(TreeNode node) =>
      node.accept(this)..fileOffset = node.fileOffset;

  TreeNode cloneOptional(TreeNode node) {
    TreeNode result = node?.accept(this);
    if (result != null) result.fileOffset = node.fileOffset;
    return result;
  }

  DartType visitType(DartType type) {
    return substitute(type, typeSubstitution);
  }

  DartType visitOptionalType(DartType type) {
    return type == null ? null : substitute(type, typeSubstitution);
  }

  visitInvalidExpression(InvalidExpression node) => new InvalidExpression();

  visitVariableGet(VariableGet node) {
    return new VariableGet(
        variables[node.variable], visitOptionalType(node.promotedType));
  }

  visitVariableSet(VariableSet node) {
    return new VariableSet(variables[node.variable], clone(node.value));
  }

  visitPropertyGet(PropertyGet node) {
    return new PropertyGet(
        clone(node.receiver), node.name, node.interfaceTarget);
  }

  visitPropertySet(PropertySet node) {
    return new PropertySet(clone(node.receiver), node.name, clone(node.value),
        node.interfaceTarget);
  }

  visitDirectPropertyGet(DirectPropertyGet node) {
    return new DirectPropertyGet(clone(node.receiver), node.target);
  }

  visitDirectPropertySet(DirectPropertySet node) {
    return new DirectPropertySet(
        clone(node.receiver), node.target, clone(node.value));
  }

  visitSuperPropertyGet(SuperPropertyGet node) {
    return new SuperPropertyGet(node.name, node.interfaceTarget);
  }

  visitSuperPropertySet(SuperPropertySet node) {
    return new SuperPropertySet(
        node.name, clone(node.value), node.interfaceTarget);
  }

  visitStaticGet(StaticGet node) {
    return new StaticGet(node.target);
  }

  visitStaticSet(StaticSet node) {
    return new StaticSet(node.target, clone(node.value));
  }

  visitMethodInvocation(MethodInvocation node) {
    return new MethodInvocation(clone(node.receiver), node.name,
        clone(node.arguments), node.interfaceTarget);
  }

  visitDirectMethodInvocation(DirectMethodInvocation node) {
    return new DirectMethodInvocation(
        clone(node.receiver), node.target, clone(node.arguments));
  }

  visitSuperMethodInvocation(SuperMethodInvocation node) {
    return new SuperMethodInvocation(
        node.name, clone(node.arguments), node.interfaceTarget);
  }

  visitStaticInvocation(StaticInvocation node) {
    return new StaticInvocation(node.target, clone(node.arguments));
  }

  visitConstructorInvocation(ConstructorInvocation node) {
    return new ConstructorInvocation(node.target, clone(node.arguments));
  }

  visitNot(Not node) {
    return new Not(clone(node.operand));
  }

  visitLogicalExpression(LogicalExpression node) {
    return new LogicalExpression(
        clone(node.left), node.operator, clone(node.right));
  }

  visitConditionalExpression(ConditionalExpression node) {
    return new ConditionalExpression(clone(node.condition), clone(node.then),
        clone(node.otherwise), visitOptionalType(node.staticType));
  }

  visitStringConcatenation(StringConcatenation node) {
    return new StringConcatenation(node.expressions.map(clone).toList());
  }

  visitIsExpression(IsExpression node) {
    return new IsExpression(clone(node.operand), visitType(node.type));
  }

  visitAsExpression(AsExpression node) {
    return new AsExpression(clone(node.operand), visitType(node.type));
  }

  visitSymbolLiteral(SymbolLiteral node) {
    return new SymbolLiteral(node.value);
  }

  visitTypeLiteral(TypeLiteral node) {
    return new TypeLiteral(visitType(node.type));
  }

  visitThisExpression(ThisExpression node) {
    return new ThisExpression();
  }

  visitRethrow(Rethrow node) {
    return new Rethrow();
  }

  visitThrow(Throw node) {
    return new Throw(cloneOptional(node.expression));
  }

  visitListLiteral(ListLiteral node) {
    return new ListLiteral(node.expressions.map(clone).toList(),
        typeArgument: visitType(node.typeArgument), isConst: node.isConst);
  }

  visitMapLiteral(MapLiteral node) {
    return new MapLiteral(node.entries.map(clone).toList(),
        keyType: visitType(node.keyType),
        valueType: visitType(node.valueType),
        isConst: node.isConst);
  }

  visitMapEntry(MapEntry node) {
    return new MapEntry(clone(node.key), clone(node.value));
  }

  visitAwaitExpression(AwaitExpression node) {
    return new AwaitExpression(clone(node.operand));
  }

  visitFunctionExpression(FunctionExpression node) {
    return new FunctionExpression(clone(node.function));
  }

  visitStringLiteral(StringLiteral node) {
    return new StringLiteral(node.value);
  }

  visitIntLiteral(IntLiteral node) {
    return new IntLiteral(node.value);
  }

  visitDoubleLiteral(DoubleLiteral node) {
    return new DoubleLiteral(node.value);
  }

  visitBoolLiteral(BoolLiteral node) {
    return new BoolLiteral(node.value);
  }

  visitNullLiteral(NullLiteral node) {
    return new NullLiteral();
  }

  visitLet(Let node) {
    var newVariable = clone(node.variable);
    return new Let(newVariable, clone(node.body));
  }

  // Statements
  visitInvalidStatement(InvalidStatement node) {
    return new InvalidStatement();
  }

  visitExpressionStatement(ExpressionStatement node) {
    return new ExpressionStatement(clone(node.expression));
  }

  visitBlock(Block node) {
    return new Block(node.statements.map(clone).toList());
  }

  visitEmptyStatement(EmptyStatement node) {
    return new EmptyStatement();
  }

  visitAssertStatement(AssertStatement node) {
    return new AssertStatement(
        clone(node.condition), cloneOptional(node.message));
  }

  visitLabeledStatement(LabeledStatement node) {
    LabeledStatement newNode = new LabeledStatement(null);
    labels[node] = newNode;
    newNode.body = clone(node.body)..parent = newNode;
    return newNode;
  }

  visitBreakStatement(BreakStatement node) {
    return new BreakStatement(labels[node.target]);
  }

  visitWhileStatement(WhileStatement node) {
    return new WhileStatement(clone(node.condition), clone(node.body));
  }

  visitDoStatement(DoStatement node) {
    return new DoStatement(clone(node.body), clone(node.condition));
  }

  visitForStatement(ForStatement node) {
    var variables = node.variables.map(clone).toList();
    return new ForStatement(variables, cloneOptional(node.condition),
        node.updates.map(clone).toList(), clone(node.body));
  }

  visitForInStatement(ForInStatement node) {
    var newVariable = clone(node.variable);
    return new ForInStatement(
        newVariable, clone(node.iterable), clone(node.body));
  }

  visitSwitchStatement(SwitchStatement node) {
    for (SwitchCase switchCase in node.cases) {
      switchCases[switchCase] =
          new SwitchCase(switchCase.expressions.map(clone).toList(), null);
    }
    return new SwitchStatement(
        clone(node.expression), node.cases.map(clone).toList());
  }

  visitSwitchCase(SwitchCase node) {
    var switchCase = switchCases[node];
    switchCase.body = clone(node.body)..parent = switchCase;
    return switchCase;
  }

  visitContinueSwitchStatement(ContinueSwitchStatement node) {
    return new ContinueSwitchStatement(switchCases[node.target]);
  }

  visitIfStatement(IfStatement node) {
    return new IfStatement(
        clone(node.condition), clone(node.then), cloneOptional(node.otherwise));
  }

  visitReturnStatement(ReturnStatement node) {
    return new ReturnStatement(cloneOptional(node.expression));
  }

  visitTryCatch(TryCatch node) {
    return new TryCatch(clone(node.body), node.catches.map(clone).toList());
  }

  visitCatch(Catch node) {
    var newException = cloneOptional(node.exception);
    var newStackTrace = cloneOptional(node.stackTrace);
    return new Catch(newException, clone(node.body),
        stackTrace: newStackTrace, guard: visitType(node.guard));
  }

  visitTryFinally(TryFinally node) {
    return new TryFinally(clone(node.body), clone(node.finalizer));
  }

  visitYieldStatement(YieldStatement node) {
    return new YieldStatement(clone(node.expression));
  }

  visitVariableDeclaration(VariableDeclaration node) {
    return variables[node] = new VariableDeclaration(node.name,
        initializer: cloneOptional(node.initializer),
        type: visitType(node.type),
        isFinal: node.isFinal,
        isConst: node.isConst);
  }

  visitFunctionDeclaration(FunctionDeclaration node) {
    var newVariable = clone(node.variable);
    return new FunctionDeclaration(newVariable, clone(node.function));
  }

  // Members
  visitConstructor(Constructor node) {
    return new Constructor(clone(node.function),
        name: node.name,
        isConst: node.isConst,
        isExternal: node.isExternal,
        initializers: node.initializers.map(clone).toList(),
        transformerFlags: node.transformerFlags);
  }

  visitProcedure(Procedure node) {
    return new Procedure(node.name, node.kind, clone(node.function),
        isAbstract: node.isAbstract,
        isStatic: node.isStatic,
        isExternal: node.isExternal,
        isConst: node.isConst,
        transformerFlags: node.transformerFlags,
        fileUri: node.fileUri);
  }

  visitField(Field node) {
    return new Field(node.name,
        type: visitType(node.type),
        initializer: cloneOptional(node.initializer),
        isFinal: node.isFinal,
        isConst: node.isConst,
        isStatic: node.isStatic,
        hasImplicitGetter: node.hasImplicitGetter,
        hasImplicitSetter: node.hasImplicitSetter,
        transformerFlags: node.transformerFlags,
        fileUri: node.fileUri);
  }

  visitTypeParameter(TypeParameter node) {
    var newNode = new TypeParameter(node.name);
    typeSubstitution[node] = new TypeParameterType(newNode);
    newNode.bound = visitType(node.bound);
    return newNode;
  }

  visitFunctionNode(FunctionNode node) {
    var typeParameters = node.typeParameters.map(clone).toList();
    var positional = node.positionalParameters.map(clone).toList();
    var named = node.namedParameters.map(clone).toList();
    return new FunctionNode(cloneOptional(node.body),
        typeParameters: typeParameters,
        positionalParameters: positional,
        namedParameters: named,
        requiredParameterCount: node.requiredParameterCount,
        returnType: visitType(node.returnType),
        asyncMarker: node.asyncMarker);
  }

  visitArguments(Arguments node) {
    return new Arguments(node.positional.map(clone).toList(),
        types: node.types.map(visitType).toList(),
        named: node.named.map(clone).toList());
  }

  visitNamedExpression(NamedExpression node) {
    return new NamedExpression(node.name, clone(node.value));
  }
}
