package com.oficina.iac;

/** Runs one FUN zero-argument Lambda handler in a fresh JVM. */
public final class FunctionHandlerColdStart {
    private FunctionHandlerColdStart() { }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Expected one handler class name");
        Class<?> handlerType = Class.forName(args[0], true, FunctionHandlerColdStart.class.getClassLoader());
        Object handler = handlerType.getConstructor().newInstance();
        if (!handlerType.isInstance(handler)) throw new IllegalStateException("Handler construction did not return its declared type");
        System.out.println("PASS: zero-argument cold start " + handlerType.getName());
    }
}
