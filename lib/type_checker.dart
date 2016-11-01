// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
library kernel.type_checker;

import 'ast.dart';
import 'class_hierarchy.dart';
import 'core_types.dart';
import 'type_algebra.dart';
import 'type_environment.dart';

/// Performs strong-mode type checking on the kernel IR.
///
/// A concrete subclass of [TypeChecker] must implement [checkAssignable] and
/// [fail] in order to deal with subtyping requirements and error handling.
abstract class TypeChecker {
  final CoreTypes coreTypes;
  final ClassHierarchy hierarchy;
  TypeEnvironment environment;

  TypeChecker(this.coreTypes, this.hierarchy) {
    environment = new TypeEnvironment(coreTypes, hierarchy);
  }

  void checkProgram(Program program) {
    for (var library in program.libraries) {
      if (library.importUri.scheme == 'dart') continue;
      for (var class_ in library.classes) {
        hierarchy.forEachOverridePair(class_,
            (Member ownMember, Member superMember, bool isSetter) {
          checkOverride(class_, ownMember, superMember, isSetter);
        });
      }
    }
    var visitor = new TypeCheckingVisitor(this, environment);
    for (var library in program.libraries) {
      if (library.importUri.scheme == 'dart') continue;
      for (var class_ in library.classes) {
        environment.thisType = class_.thisType;
        for (var field in class_.fields) {
          visitor.visitField(field);
        }
        for (var constructor in class_.constructors) {
          visitor.visitConstructor(constructor);
        }
        for (var procedure in class_.procedures) {
          visitor.visitProcedure(procedure);
        }
      }
      environment.thisType = null;
      for (var procedure in library.procedures) {
        visitor.visitProcedure(procedure);
      }
      for (var field in library.fields) {
        visitor.visitField(field);
      }
    }
  }

  DartType getterType(Class host, Member member) {
    var hostType = hierarchy.getClassAsInstanceOf(host, member.enclosingClass);
    var substitution = Substitution.fromSupertype(hostType);
    return substitution.substituteType(member.getterType);
  }

  DartType setterType(Class host, Member member) {
    var hostType = hierarchy.getClassAsInstanceOf(host, member.enclosingClass);
    var substitution = Substitution.fromSupertype(hostType);
    return substitution.substituteType(member.setterType, contravariant: true);
  }

  void checkOverride(
      Class host, Member ownMember, Member superMember, bool isSetter) {
    if (isSetter) {
      checkAssignable(ownMember, setterType(host, superMember),
          setterType(host, ownMember));
    } else {
      checkAssignable(ownMember, getterType(host, ownMember),
          getterType(host, superMember));
    }
  }

  /// Check that [from] is a subtype of [to].
  ///
  /// [where] is an AST node indicating roughly where the check is required.
  void checkAssignable(TreeNode where, DartType from, DartType to);

  /// Indicates that type checking failed.
  void fail(TreeNode where, String message);
}

class TypeCheckingVisitor
    implements
        ExpressionVisitor<DartType>,
        StatementVisitor<Null>,
        MemberVisitor<Null>,
        InitializerVisitor<Null> {
  final TypeChecker checker;
  final TypeEnvironment environment;

  CoreTypes get coreTypes => environment.coreTypes;
  ClassHierarchy get hierarchy => environment.hierarchy;
  Class get currentClass => environment.thisType.classNode;

  TypeCheckingVisitor(this.checker, this.environment);

  void checkAssignable(TreeNode where, DartType from, DartType to) {
    checker.checkAssignable(where, from, to);
  }

  void checkAssignableExpression(Expression from, DartType to) {
    checker.checkAssignable(from, visitExpression(from), to);
  }

  void fail(TreeNode node, String message) {
    checker.fail(node, message);
  }

  DartType visitExpression(Expression node) => node.accept(this);

  void visitStatement(Statement node) {
    node.accept(this);
  }

  void visitInitializer(Initializer node) {
    node.accept(this);
  }

  defaultMember(Member node) => throw 'Unused';

  DartType defaultBasicLiteral(BasicLiteral node) {
    return defaultExpression(node);
  }

  DartType defaultExpression(Expression node) {
    throw 'Unexpected expression ${node.runtimeType}';
  }

  defaultStatement(Statement node) {
    throw 'Unexpected statement ${node.runtimeType}';
  }

  defaultInitializer(Initializer node) {
    throw 'Unexpected initializer ${node.runtimeType}';
  }

  visitField(Field node) {
    if (node.initializer != null) {
      checkAssignableExpression(node.initializer, node.type);
    }
  }

  visitConstructor(Constructor node) {
    environment.returnType = null;
    environment.yieldType = null;
    node.initializers.forEach(visitInitializer);
    handleFunctionNode(node.function);
  }

  visitProcedure(Procedure node) {
    environment.returnType = node.function.returnType;
    environment.yieldType = _getYieldType(node.function);
    handleFunctionNode(node.function);
  }

  void handleFunctionNode(FunctionNode node) {
    node.positionalParameters
        .skip(node.requiredParameterCount)
        .forEach(handleOptionalParameter);
    node.namedParameters.forEach(handleOptionalParameter);
    if (node.body != null) {
      visitStatement(node.body);
    }
  }

  void handleNestedFunctionNode(FunctionNode node) {
    var oldReturn = environment.returnType;
    var oldYield = environment.yieldType;
    environment.returnType = node.returnType;
    environment.yieldType = _getYieldType(node);
    handleFunctionNode(node);
    environment.returnType = oldReturn;
    environment.yieldType = oldYield;
  }

  void handleOptionalParameter(VariableDeclaration parameter) {
    if (parameter.initializer != null) {
      checkAssignableExpression(parameter.initializer, parameter.type);
    }
  }

  Substitution getReceiverType(
      TreeNode access, Expression receiver, Member member) {
    var type = visitExpression(receiver);
    Class superclass = member.enclosingClass;
    if (superclass.supertype == null) {
      return Substitution.empty; // Members on Object are always accessible.
    }
    while (type is TypeParameterType) {
      type = (type as TypeParameterType).parameter.bound;
    }
    if (type is BottomType) {
      // The bottom type is a subtype of all types, so it should be allowed.
      return Substitution.bottomForClass(superclass);
    }
    if (type is InterfaceType) {
      // The receiver type should implement the interface declaring the member.
      var upcastType = hierarchy.getTypeAsInstanceOf(type, superclass);
      if (upcastType != null) {
        return Substitution.fromInterfaceType(upcastType);
      }
    }
    if (type is FunctionType && superclass == coreTypes.functionClass) {
      assert(type.typeParameters.isEmpty);
      return Substitution.empty;
    }
    // Note that we do not allow 'dynamic' here.  Dynamic calls should not
    // have a declared interface target.
    fail(access, '$member is not accessible on a receiver of type $type');
    return Substitution.bottomForClass(superclass); // Continue type checking.
  }

  Substitution getSuperReceiverType(Member member) {
    return Substitution.fromSupertype(
        hierarchy.getClassAsInstanceOf(currentClass, member.enclosingClass));
  }

  DartType handleCall(Arguments arguments, FunctionNode function,
      {Substitution receiver: Substitution.empty,
      List<TypeParameter> typeParameters}) {
    typeParameters ??= function.typeParameters;
    if (arguments.positional.length < function.requiredParameterCount) {
      fail(arguments, 'Too few positional arguments');
      return const BottomType();
    }
    if (arguments.positional.length > function.positionalParameters.length) {
      fail(arguments, 'Too many positional arguments');
      return const BottomType();
    }
    if (arguments.types.length != typeParameters.length) {
      fail(arguments, 'Wrong number of type arguments');
      return const BottomType();
    }
    var instantiation = Substitution.fromPairs(typeParameters, arguments.types);
    var substitution = Substitution.combine(receiver, instantiation);
    for (int i = 0; i < typeParameters.length; ++i) {
      var argument = arguments.types[i];
      var bound = substitution.substituteType(typeParameters[i].bound);
      checkAssignable(arguments, argument, bound);
    }
    for (int i = 0; i < arguments.positional.length; ++i) {
      var expectedType = substitution.substituteType(
          function.positionalParameters[i].type,
          contravariant: true);
      checkAssignableExpression(arguments.positional[i], expectedType);
    }
    for (int i = 0; i < arguments.named.length; ++i) {
      var argument = arguments.named[i];
      bool found = false;
      for (int j = 0; j < function.namedParameters.length; ++j) {
        if (argument.name == function.namedParameters[j].name) {
          var expectedType = substitution.substituteType(
              function.namedParameters[j].type,
              contravariant: true);
          checkAssignableExpression(argument.value, expectedType);
          found = true;
          break;
        }
      }
      if (!found) {
        fail(argument.value, 'Unexpected named parameter: ${argument.name}');
        return const BottomType();
      }
    }
    return substitution.substituteType(function.returnType);
  }

  DartType _getYieldType(FunctionNode function) {
    switch (function.asyncMarker) {
      case AsyncMarker.Sync:
      case AsyncMarker.Async:
        return null;

      case AsyncMarker.SyncStar:
      case AsyncMarker.AsyncStar:
        Class container = function.asyncMarker == AsyncMarker.SyncStar
            ? coreTypes.iterableClass
            : coreTypes.streamClass;
        DartType returnType = function.returnType;
        if (returnType is InterfaceType && returnType.classNode == container) {
          return returnType.typeArguments.single;
        }
        return const DynamicType();

      case AsyncMarker.SyncYielding:
        return function.returnType;

      default:
        throw 'Unexpected async marker: ${function.asyncMarker}';
    }
  }

  @override
  DartType visitAsExpression(AsExpression node) {
    visitExpression(node.operand);
    return node.type;
  }

  @override
  DartType visitAwaitExpression(AwaitExpression node) {
    return environment.unfutureType(visitExpression(node.operand));
  }

  @override
  DartType visitBoolLiteral(BoolLiteral node) {
    return environment.boolType;
  }

  @override
  DartType visitConditionalExpression(ConditionalExpression node) {
    checkAssignableExpression(node.condition, environment.boolType);
    if (node.staticType == null) {
      var thenType = visitExpression(node.then);
      var otherwiseType = visitExpression(node.otherwise);
      if (thenType is BottomType) return otherwiseType;
      if (otherwiseType is BottomType) return thenType;
      return const DynamicType();
    } else {
      checkAssignableExpression(node.then, node.staticType);
      checkAssignableExpression(node.otherwise, node.staticType);
      return node.staticType;
    }
  }

  @override
  DartType visitConstructorInvocation(ConstructorInvocation node) {
    Constructor target = node.target;
    Arguments arguments = node.arguments;
    Class class_ = target.enclosingClass;
    handleCall(arguments, target.function,
        typeParameters: class_.typeParameters);
    return new InterfaceType(target.enclosingClass, arguments.types);
  }

  @override
  DartType visitDirectMethodInvocation(DirectMethodInvocation node) {
    return handleCall(node.arguments, node.target.function,
        receiver: getReceiverType(node, node.receiver, node.target));
  }

  @override
  DartType visitDirectPropertyGet(DirectPropertyGet node) {
    var receiver = getReceiverType(node, node.receiver, node.target);
    return receiver.substituteType(node.target.getterType);
  }

  @override
  DartType visitDirectPropertySet(DirectPropertySet node) {
    var receiver = getReceiverType(node, node.receiver, node.target);
    var value = visitExpression(node.value);
    checkAssignable(node, value,
        receiver.substituteType(node.target.setterType, contravariant: true));
    return value;
  }

  @override
  DartType visitDoubleLiteral(DoubleLiteral node) {
    return environment.doubleType;
  }

  @override
  DartType visitFunctionExpression(FunctionExpression node) {
    handleNestedFunctionNode(node.function);
    return node.function.functionType;
  }

  @override
  DartType visitIntLiteral(IntLiteral node) {
    return environment.intType;
  }

  @override
  DartType visitInvalidExpression(InvalidExpression node) {
    return const BottomType();
  }

  @override
  DartType visitIsExpression(IsExpression node) {
    visitExpression(node.operand);
    return environment.boolType;
  }

  @override
  DartType visitLet(Let node) {
    var value = visitExpression(node.variable.initializer);
    if (node.variable.type is DynamicType) {
      node.variable.type = value;
    }
    return visitExpression(node.body);
  }

  @override
  DartType visitListLiteral(ListLiteral node) {
    for (var item in node.expressions) {
      checkAssignableExpression(item, node.typeArgument);
    }
    return environment.literalListType(node.typeArgument);
  }

  @override
  DartType visitLogicalExpression(LogicalExpression node) {
    checkAssignableExpression(node.left, environment.boolType);
    checkAssignableExpression(node.right, environment.boolType);
    return environment.boolType;
  }

  @override
  DartType visitMapLiteral(MapLiteral node) {
    for (var entry in node.entries) {
      checkAssignableExpression(entry.key, node.keyType);
      checkAssignableExpression(entry.value, node.valueType);
    }
    return environment.literalMapType(node.keyType, node.valueType);
  }

  DartType handleDynamicCall(DartType receiver, Arguments arguments) {
    arguments.positional.forEach(visitExpression);
    arguments.named.forEach((NamedExpression n) => visitExpression(n.value));
    return const DynamicType();
  }

  DartType handleFunctionCall(
      TreeNode access, FunctionType function, Arguments arguments) {
    if (function.requiredParameterCount > arguments.positional.length) {
      fail(access, 'Too few positional arguments');
      return const BottomType();
    }
    if (function.positionalParameters.length < arguments.positional.length) {
      fail(access, 'Too many positional arguments');
      return const BottomType();
    }
    if (function.typeParameters.length != arguments.types.length) {
      fail(access, 'Wrong number of type arguments');
      return const BottomType();
    }
    var instantiation =
        Substitution.fromPairs(function.typeParameters, arguments.types);
    for (int i = 0; i < arguments.positional.length; ++i) {
      var expectedType = instantiation.substituteType(
          function.positionalParameters[i],
          contravariant: true);
      checkAssignableExpression(arguments.positional[i], expectedType);
    }
    for (int i = 0; i < arguments.named.length; ++i) {
      var argument = arguments.named[i];
      var expectedType = function.namedParameters[argument.name];
      if (expectedType == null) {
        fail(argument.value, 'Unexpected named parameter: ${argument.name}');
      } else {
        checkAssignableExpression(argument.value,
            instantiation.substituteType(expectedType, contravariant: true));
      }
    }
    return instantiation.substituteType(function.returnType);
  }

  @override
  DartType visitMethodInvocation(MethodInvocation node) {
    var target = node.interfaceTarget;
    if (target == null) {
      var receiver = visitExpression(node.receiver);
      return (node.name.name == 'call' && receiver is FunctionType)
          ? handleFunctionCall(node, receiver, node.arguments)
          : handleDynamicCall(receiver, node.arguments);
    } else if (environment.isOverloadedArithmeticOperator(target)) {
      assert(node.arguments.positional.length == 1);
      var receiver = visitExpression(node.receiver);
      var argument = visitExpression(node.arguments.positional[0]);
      return environment.getTypeOfOverloadedArithmetic(receiver, argument);
    } else {
      return handleCall(node.arguments, target.function,
          receiver: getReceiverType(node, node.receiver, node.interfaceTarget));
    }
  }

  @override
  DartType visitPropertyGet(PropertyGet node) {
    if (node.interfaceTarget == null) {
      visitExpression(node.receiver);
      return const DynamicType();
    } else {
      var receiver = getReceiverType(node, node.receiver, node.interfaceTarget);
      return receiver.substituteType(node.interfaceTarget.getterType);
    }
  }

  @override
  DartType visitPropertySet(PropertySet node) {
    var value = visitExpression(node.value);
    if (node.interfaceTarget != null) {
      var receiver = getReceiverType(node, node.receiver, node.interfaceTarget);
      checkAssignable(
          node.value,
          value,
          receiver.substituteType(node.interfaceTarget.setterType,
              contravariant: true));
    } else {
      visitExpression(node.receiver);
    }
    return value;
  }

  @override
  DartType visitNot(Not node) {
    visitExpression(node.operand);
    return environment.boolType;
  }

  @override
  DartType visitNullLiteral(NullLiteral node) {
    return const BottomType();
  }

  @override
  DartType visitRethrow(Rethrow node) {
    return const BottomType();
  }

  @override
  DartType visitStaticGet(StaticGet node) {
    return node.target.getterType;
  }

  @override
  DartType visitStaticInvocation(StaticInvocation node) {
    return handleCall(node.arguments, node.target.function);
  }

  @override
  DartType visitStaticSet(StaticSet node) {
    var value = visitExpression(node.value);
    checkAssignable(node.value, value, node.target.setterType);
    return value;
  }

  @override
  DartType visitStringConcatenation(StringConcatenation node) {
    node.expressions.forEach(visitExpression);
    return environment.stringType;
  }

  @override
  DartType visitStringLiteral(StringLiteral node) {
    return environment.stringType;
  }

  @override
  DartType visitSuperMethodInvocation(SuperMethodInvocation node) {
    if (node.interfaceTarget == null) {
      return handleDynamicCall(environment.thisType, node.arguments);
    } else {
      return handleCall(node.arguments, node.interfaceTarget.function,
          receiver: getSuperReceiverType(node.interfaceTarget));
    }
  }

  @override
  DartType visitSuperPropertyGet(SuperPropertyGet node) {
    if (node.interfaceTarget == null) {
      return const DynamicType();
    } else {
      var receiver = getSuperReceiverType(node.interfaceTarget);
      return receiver.substituteType(node.interfaceTarget.getterType);
    }
  }

  @override
  DartType visitSuperPropertySet(SuperPropertySet node) {
    var value = visitExpression(node.value);
    if (node.interfaceTarget != null) {
      var receiver = getSuperReceiverType(node.interfaceTarget);
      checkAssignable(
          node.value,
          value,
          receiver.substituteType(node.interfaceTarget.setterType,
              contravariant: true));
    }
    return value;
  }

  @override
  DartType visitSymbolLiteral(SymbolLiteral node) {
    return environment.symbolType;
  }

  @override
  DartType visitThisExpression(ThisExpression node) {
    return environment.thisType;
  }

  @override
  DartType visitThrow(Throw node) {
    visitExpression(node.expression);
    return const BottomType();
  }

  @override
  DartType visitTypeLiteral(TypeLiteral node) {
    return environment.typeType;
  }

  @override
  DartType visitVariableGet(VariableGet node) {
    return node.promotedType ?? node.variable.type;
  }

  @override
  DartType visitVariableSet(VariableSet node) {
    var value = visitExpression(node.value);
    checkAssignable(node.value, value, node.variable.type);
    return value;
  }

  @override
  visitAssertStatement(AssertStatement node) {
    visitExpression(node.condition);
    if (node.message != null) {
      visitExpression(node.message);
    }
  }

  @override
  visitBlock(Block node) {
    node.statements.forEach(visitStatement);
  }

  @override
  visitBreakStatement(BreakStatement node) {}

  @override
  visitContinueSwitchStatement(ContinueSwitchStatement node) {}

  @override
  visitDoStatement(DoStatement node) {
    visitStatement(node.body);
    checkAssignableExpression(node.condition, environment.boolType);
  }

  @override
  visitEmptyStatement(EmptyStatement node) {}

  @override
  visitExpressionStatement(ExpressionStatement node) {
    visitExpression(node.expression);
  }

  @override
  visitForInStatement(ForInStatement node) {
    var iterable = visitExpression(node.iterable);
    // TODO(asgerf): Store interface targets on for-in loops or desugar them,
    // instead of doing the ad-hoc resolution here.
    if (node.isAsync) {
      checkAssignable(node, getStreamElementType(iterable), node.variable.type);
    } else {
      checkAssignable(
          node, getIterableElementType(iterable), node.variable.type);
    }
    visitStatement(node.body);
  }

  static final Name iteratorName = new Name('iterator');
  static final Name nextName = new Name('next');

  DartType getIterableElementType(DartType iterable) {
    if (iterable is InterfaceType) {
      var iteratorGetter =
          hierarchy.getInterfaceMember(iterable.classNode, iteratorName);
      if (iteratorGetter == null) return const DynamicType();
      var iteratorType = Substitution
          .fromInterfaceType(iterable)
          .substituteType(iteratorGetter.getterType);
      if (iteratorType is InterfaceType) {
        var nextGetter =
            hierarchy.getInterfaceMember(iteratorType.classNode, nextName);
        if (nextGetter == null) return const DynamicType();
        return Substitution
            .fromInterfaceType(iteratorType)
            .substituteType(nextGetter.getterType);
      }
    }
    return const DynamicType();
  }

  DartType getStreamElementType(DartType stream) {
    if (stream is InterfaceType) {
      var asStream =
          hierarchy.getTypeAsInstanceOf(stream, coreTypes.streamClass);
      if (asStream == null) return const DynamicType();
      return asStream.typeArguments.single;
    }
    return const DynamicType();
  }

  @override
  visitForStatement(ForStatement node) {
    node.variables.forEach(visitVariableDeclaration);
    if (node.condition != null) {
      checkAssignableExpression(node.condition, environment.boolType);
    }
    node.updates.forEach(visitExpression);
    visitStatement(node.body);
  }

  @override
  visitFunctionDeclaration(FunctionDeclaration node) {
    handleNestedFunctionNode(node.function);
  }

  @override
  visitIfStatement(IfStatement node) {
    checkAssignableExpression(node.condition, environment.boolType);
    visitStatement(node.then);
    if (node.otherwise != null) {
      visitStatement(node.otherwise);
    }
  }

  @override
  visitInvalidStatement(InvalidStatement node) {}

  @override
  visitLabeledStatement(LabeledStatement node) {
    visitStatement(node.body);
  }

  @override
  visitReturnStatement(ReturnStatement node) {
    if (node.expression != null) {
      if (environment.returnType == null) {
        fail(node, 'Return of a value from void method');
      } else {
        checkAssignableExpression(node.expression, environment.returnType);
      }
    }
  }

  @override
  visitSwitchStatement(SwitchStatement node) {
    visitExpression(node.expression);
    for (var switchCase in node.cases) {
      switchCase.expressions.forEach(visitExpression);
      visitStatement(switchCase.body);
    }
  }

  @override
  visitTryCatch(TryCatch node) {
    visitStatement(node.body);
    for (var catchClause in node.catches) {
      visitStatement(catchClause.body);
    }
  }

  @override
  visitTryFinally(TryFinally node) {
    visitStatement(node.body);
    visitStatement(node.finalizer);
  }

  @override
  visitVariableDeclaration(VariableDeclaration node) {
    if (node.initializer != null) {
      checkAssignableExpression(node.initializer, node.type);
    }
  }

  @override
  visitWhileStatement(WhileStatement node) {
    checkAssignableExpression(node.condition, environment.boolType);
    visitStatement(node.body);
  }

  @override
  visitYieldStatement(YieldStatement node) {
    checkAssignableExpression(node.expression, environment.yieldType);
  }

  @override
  visitFieldInitializer(FieldInitializer node) {
    checkAssignableExpression(node.value, node.field.type);
  }

  @override
  visitRedirectingInitializer(RedirectingInitializer node) {
    handleCall(node.arguments, node.target.function,
        typeParameters: const <TypeParameter>[]);
  }

  @override
  visitSuperInitializer(SuperInitializer node) {
    handleCall(node.arguments, node.target.function,
        typeParameters: const <TypeParameter>[]);
  }

  @override
  visitLocalInitializer(LocalInitializer node) {
    visitVariableDeclaration(node.variable);
  }

  @override
  visitInvalidInitializer(InvalidInitializer node) {}
}
