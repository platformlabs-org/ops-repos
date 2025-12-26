"use strict";

//**************************************************************************
// CodeFlow.js:
//
// Uses the ApiExtension Code library to perform analysis about data flow
// within a function.
//
// Usage: !dflow <address>
//
//     Disassembles the function containing <address>, finds any instruction
//     in the control flow which influences the source operands of the instruction
//     at <address> and adds such instruction to the output collection.
//
// @TODO:
// 
//     - !dflow should be able to work without any symbolic information given a range
//       of assembly instructions to consider for the analysis
//

var __diagLevel = 0; // 1 is most important, increasingly less

function __diag(level)
{
    return (level <= __diagLevel);
}

class __TraceDataFlow
{
    constructor(disassembler, functionDisassembly, address)
    {
        this.__disassembler = disassembler;
        this.__functionDisassembly = functionDisassembly;
        this.__address = address;
    }

    toString()
    {
        var instr = this.__disassembler.DisassembleInstructions(this.__address).First();

        var str = "Traced data flow of " + this.__address.toString(16) + ": " + instr +") for source operands { ";
        var first = true;
        for (var operand of instr.Operands)
        {
            if (operand.Attributes.IsInput)
            {
                if (!first)
                {
                    str += ", ";
                }
                first = false;
                str += operand;
            }
        }
        str += " }";

        return str;
    }

    // __findBasicBlock:
    //
    // Finds a basic block containing the instruction at the given address.
    //
    __findBasicBlock(address)
    {
        var predicate = function(b) { return (address.compareTo(b.StartAddress) >= 0 && address.compareTo(b.EndAddress) < 0); } 
        return this.__functionDisassembly.BasicBlocks.First(predicate);
    }

    // __dumpRegisterSet:
    //
    // Diagnostic method to dump a register set.
    //
    __dumpRegisterSet(registerSet)
    {
        host.diagnostics.debugLog("    Register Set== ");
        for (var setReg of registerSet)
        {
            host.diagnostics.debugLog("'", this.__disassembler.GetRegister(setReg), "'(", setReg, "), ");
        }
        host.diagnostics.debugLog("\n");
    }

    // __addRegisterReferences:
    //
    // Adds a register (and all sub-registers) to a register set.
    //
    __addRegisterReferences(registerSet, reg)
    {
        registerSet.add(reg.Id);
        for(var subReg of reg.GetSubRegisters())
        {
            registerSet.add(subReg.Id);
        }
    }

    // __removeRegisterReferences:
    //
    // Removes a register (and all sub-registers) from a register set.
    //
    __removeRegisterReferences(registerSet, reg)
    {
        registerSet.delete(reg.Id);
        for(var subReg of reg.GetSubRegisters())
        {
            registerSet.delete(subReg.Id);
        }
    }

    // __hasRegisterReference
    //
    // Is the register 'reg' (or any sub-register) in the register set.
    //
    __hasRegisterReference(registerSet, reg)
    {
        if (__diag(3))
        {
            this.__dumpRegisterSet(registerSet);
            host.diagnostics.debugLog("    Comparison Set== '", reg, "'(", reg.Id, "), ");
            for( var subReg of reg.GetSubRegisters())
            {
                host.diagnostics.debugLog("'", subReg, "'(", subReg.Id, "), ");
            }
            host.diagnostics.debugLog("\n");
        }

        if (registerSet.has(reg.Id))
        {
            return true;
        }

        for (var subReg of reg.GetSubRegisters())
        {
            if (registerSet.has(subReg.Id))
            {
                return true;
            }
        }

        return false;
    }

    // __hasWriteOfMemory:
    //
    // Determines whether an operand in the set writes to memory in the memory reference set.
    //
    __hasWriteOfMemory(operandSet, memoryReferences)
    {
        for (var operand of operandSet)
        {
            var attrs = operand.Attributes;
            if (attrs.IsOutput && attrs.IsMemoryReference)
            {
                for (var ref of memoryReferences)
                {
                    if (__diag(5))
                    {
                        host.diagnostics.debugLog("    Checking '" + operand + "' against '" + ref + "'\n");
                    }

                    if (operand.ReferencesSameMemory(ref))
                    {
                        if (__diag(5))
                        {
                            host.diagnostics.debugLog("         Match on memory write!\n");
                        }
                        return true;
                    }
                }
            }
        }

        return false;
    }

    // __writesToRegister
    //
    // Determines whether an operand is a write to a register in a register reference set.
    //
    __writesToRegister(instr, operandSet, registerReferences)
    {
        for (var operand of operandSet)
        {
            var attrs = operand.Attributes;
            if (attrs.IsOutput && attrs.IsRegister)
            {
                for (var reg of registerReferences)
                {
                    if (operand.UsesRegister(reg))
                    {
                        return true;
                    }
                }
            }
        }

        if (instr.Attributes.IsCall)
        {
            var retReg = instr.Attributes.ReturnRegister;

            if (__diag(2))
            {
                host.diagnostics.debugLog("Check for return register '", retReg, "' in instruction '", instr, "'\n");
            }
            
            if (retReg !== undefined)
            {
                if (__diag(2))
                {
                    host.diagnostics.debugLog("    Check id == ", retReg.Id, "\n");
                }

                if (this.__hasRegisterReference(registerReferences, retReg))
                {
                    return true;
                }
            }
        }

        return false;
    }

    // __kill:
    //
    // Removes a set of registers from the register set.
    //
    __kill(registerSet, registerReferences)
    {
        for(var reg of registerSet)
        {
            this.__removeRegisterReferences(registerReferences, reg);
        }
    }

    // __live:
    //
    // Makes a set of registers live in the register set.
    //
    __live(registerSet, registerReferences)
    {
        for (var reg of registerSet)
        {
            this.__addRegisterReferences(registerReferences, reg);
        }
    }

    // __killMemoryReference:
    //
    // Removes a memory reference from the set of live memory references.
    //
    __killMemoryReference(memRef, memoryReferences)
    {
        var i = 0;
        var len = memoryReferences.length;
        while (i < len)
        {
            if (memRef.ReferencesSameMemory(memoryReferences[i]))
            {
                memoryReferences.splice(i, 1);
                break;
            }
            ++i;
        }
    }

    // __liveMemoryReference:
    //
    // Adds a memory reference to the set of live memory references.
    //
    __liveMemoryReference(memRef, memoryReferences)
    {
        var i = 0;
        var len = memoryReferences.length;
        while (i < len)
        {
            if (memRef.ReferencesSameMemory(memoryReferences[i]))
            {
                return;
            }
            ++i;
        }
        memoryReferences.push(memRef);
    }

    // __addCallInputRegisters:
    //
    // Make an attempt to determine what were register inputs to the call and add them to the
    // lifetime set.  This is done by looking at the call target, disassembling it, looking
    // at the first instruction and whether any variables are live in registers as of the 
    // first instruction of the call target.
    //
    __addCallInputRegisters(instr, registerReferences)
    {
        if (__diag(4))
        {
            host.diagnostics.debugLog("Looking at call for inputs: '", instr, "'\n");
        }
   
        var callTarget;
        try
        {
            //
            // We may not be able to read this.  If we cannot, don't bother.
            //
            var opCount = instr.Operands.Count();
            if (opCount == 1)
            {
                var destOperand = instr.Operands.First();
                var attrs = destOperand.Attributes;

                if (attrs.IsImmediate)
                {
                    callTarget = destOperand.ImmediateValue;
                    if (__diag(2))
                    {
                        host.diagnostics.debugLog("Call has direct target: '", callTarget, "'\n");
                    }
                }
                else if (attrs.HasImmediate && attrs.IsMemoryReference && destOperand.Registers.Count() == 0)
                {
                    //
                    // @TODO: This should be sizeof(*) and *NOT* hard code to 64-bit.
                    //
                    var indirectCallTarget = destOperand.ImmediateValue;
                    if (__diag(2))
                    {
                        host.diagnostics.debugLog("Call has indirect target: '", indirectCallTarget, "'\n");
                    }

                    var tableRead = host.memory.readMemoryValues(indirectCallTarget, 1, 8, false);
                    callTarget = tableRead[0];

                    if (__diag(2))
                    {
                        host.diagnostics.debugLog("    Call destination read: '", callTarget, "'\n");
                    }
                }
            }
        }
        catch(exc1)
        {
        }

        try
        {
            //
            // We may not be able to read and disassemble the call target.  If we cannot, don't bother.
            //
            if (callTarget !== undefined)
            {
                //
                // We found the call target.  Disassemble it, get the first instruction, and go through all
                // live variables which are enregistered at this point.
                //
                var targetDis = this.__disassembler.DisassembleInstructions(callTarget);
                var firstInstr = targetDis.First();
                if (__diag(1))
                {
                    host.diagnostics.debugLog("Looking at call destination instruction '", firstInstr, "' for live variables.\n");
                }
                for (var liveVar of firstInstr.LiveVariables)
                {
                    if (liveVar.LocationKind == "Register" && liveVar.Offset == 0)
                    {
                        if (__diag(1))
                        {
                            host.diagnostics.debugLog("    Found call input register '", liveVar.Register, "'\n");
                        }
                        this.__addRegisterReferences(registerReferences, liveVar.Register);
                    }
                }
            }
        }
        catch(exc2)
        {
        }
    }

    // __reformLifetimes
    //
    // Performs any kills of written registers or memory references and 
    // adds all source registers and memory references to the set
    //
    // @TODO: If we pass the operandSet instead of instr, the second for...of will crash.  Fix!
    //
    __reformLifetimes(instr, registerReferences, memoryReferences)
    {
        if (instr.Attributes.IsCall)
        {
            var setCopy = new Set(registerReferences);
            for (var regId of setCopy)
            {
                var preserves = instr.PreservesRegisterValue(regId);
                if (__diag(3))
                {
                    host.diagnostics.debugLog("    Check preservation of (", regId, ") == ", preserves, "\n");
                }
                if (!preserves)
                {
                    this.__removeRegisterReferences(registerReferences, this.__disassembler.GetRegister(regId));
                }
            }
        }
        else
        {
            for (var operand of instr.Operands /*operandSet*/)
            {
                var attrs = operand.Attributes;
                if (attrs.IsOutput)
                {
                    if (attrs.IsRegister)
                    {
                        //
                        // Kill the registers.
                        //
                        this.__kill(operand.Registers, registerReferences);
                    }
                    else if (attrs.IsMemoryReference)
                    {
                        //
                        // Is there a memory reference in the array.
                        //
                        this.__killMemoryReference(operand, memoryReferences);
                    }
                }
            }
        }

        for (var operand of instr.Operands /*operandSet*/)
        {
            var attrs = operand.Attributes;
            if (attrs.IsInput)
            {
                this.__live(operand.Registers, registerReferences);
                if (attrs.IsMemoryReference)
                {
                    this.__liveMemoryReference(operand, memoryReferences);
                }
            }
        }

        //
        // If we have a call and can determine register passed values, do so.
        //
        if (instr.Attributes.IsCall)
        {
            this.__addCallInputRegisters(instr, registerReferences);
        }
    }

    // __dbgOutputSets:
    //
    // Diagnostic helper to output the live register and memory sets.
    //
    __dbgOutputSets(msg, registerReferences, memoryReferences)
    {
        if (__diag(2))
        {
            host.diagnostics.debugLog(msg, "\n");
            for (var regRef of registerReferences)
            {
                host.diagnostics.debugLog("    ", regRef, "\n");
            }
            for (var memRef of memoryReferences)
            {
                host.diagnostics.debugLog("    ", memRef, "\n");
            }
        }
    }

    // __scanBlockBackwards:
    //
    // For the given basic block, an instruction within that block
    // scan the block backwards looking for instructions that write to the source operands. 
    //
    // If one of the sources is written to, kill it from the scan.
    //
    *__scanBlockBackwards(basicBlock, instruction, registerReferences, memoryReferences, skipInstruction)
    {
        if (this.__exploredBlocks.has(basicBlock.StartAddress))
        {
            return;
        }
        this.__exploredBlocks.add(basicBlock.StartAddress);

        this.__dbgOutputSets("Scan: ", registerReferences, memoryReferences);

        //
        // Get the set of instructions in the basic block and walk them backwards.
        //
        var blockBackwards = basicBlock.Instructions.Reverse();
        var hitInstr = false;
        var address = instruction.Address;
        for (var instr of blockBackwards)
        {
            //
            // We have to get to the instruction in reverse first.
            //
            if (!hitInstr)
            {
                if (instr.Address.compareTo(address) == 0)
                {
                    hitInstr = true;
                }

                if (!hitInstr || skipInstruction)
                {
                    continue;
                }
            }

            //
            // This is in the basic block *BEFORE* the starting instruction.
            //
            if (__diag(2))
            {
                host.diagnostics.debugLog("Looking at instruction '", instr, "'\n");
            }

            //
            // If we have an instruction that writes to the same memory, it matches.
            //
            // If we have an instruction that writes to a referenced register, it matches -- add the source registers,
            //     and kill the destination registers.
            //
            var hasSameMemRef = this.__hasWriteOfMemory(instr.Operands, memoryReferences);
            var hasRegRef = this.__writesToRegister(instr, instr.Operands, registerReferences);

            if (__diag(5))
            {
                host.diagnostics.debugLog("    Has write: '", hasSameMemRef, "'\n");
                host.diagnostics.debugLog("    Has reg  : '", hasRegRef, "'\n");
            }

            if (hasSameMemRef || hasRegRef)
            {
                yield new host.indexedValue(instr, [instr.Address]);

                //
                // Once we have yielded that instruction, change the live register set.  Kill anything written
                // in instr and add anything read.
                //
                this.__reformLifetimes(instr, registerReferences, memoryReferences);
                this.__dbgOutputSets("Reform: ", registerReferences, memoryReferences);
            }
        }

        if (__diag(1))
        {
            host.diagnostics.debugLog("Traverse to blocks:\n");
            for (var inboundFlow of basicBlock.InboundControlFlows)
            {
                host.diagnostics.debugLog("    ", inboundFlow.LinkedBlock, "\n");
            }
        }

        //
        // The basic block has entries from other blocks, scan them.
        //
        for (var inboundFlow of basicBlock.InboundControlFlows)
        {
            var childSet = new Set(registerReferences);
            var childMem = memoryReferences.slice();
            yield* this.__scanBlockBackwards(inboundFlow.LinkedBlock, inboundFlow.SourceInstruction, childSet, childMem, false);
        }
    }

    // [Symbol.iterator]:
    //
    // Find all instructions in the data flow.
    //
    *[Symbol.iterator]()
    {
        this.__exploredBlocks = new Set();

        //
        // Find the starting instruction.  It is obviously part of the data flow.
        //
        var startingBlock = this.__findBasicBlock(this.__address);
        var startingInstruction = startingBlock.Instructions.getValueAt(this.__address);
        yield new host.indexedValue(startingInstruction, [startingInstruction.Address]);

        var memoryReferences = [];
        var registerReferences = new Set();

        if (__diag(2))
        {
            host.diagnostics.debugLog("Starting Instruction: ", startingInstruction, "\n");
        }
        for (var operand of startingInstruction.Operands)
        {
            if (__diag(5))
            {
                host.diagnostics.debugLog("Is '", operand, "' a source?\n");
            }
            var attrs = operand.Attributes;
            if (attrs.IsInput)
            {
                if (__diag(5))
                {
                    host.diagnostics.debugLog("    Yes\n");
                }
                if (attrs.IsMemoryReference)
                {
                    if (__diag(5))
                    {
                        host.diagnostics.debugLog("MemRef: ", operand, "\n");
                    }
                    memoryReferences.push(operand);
                }

                for (var reg of operand.Registers)
                {
                    if (__diag(5))
                    {
                        host.diagnostics.debugLog("RegRef: ", reg, "\n");
                    }
                    this.__addRegisterReferences(registerReferences, reg);
                }
            }
        }

        yield* this.__scanBlockBackwards(startingBlock, startingInstruction, registerReferences, memoryReferences, true);
    }

    // getDimensionality:
    //
    // Return the dimensionality of our indexer (1 -- by instruction address)
    //
    getDimensionality()
    {
        return 1;
    }

    // getValueAt:
    //
    // Return the instruction at the given address.  @TODO: It would be nice if this only allowed indexing
    // instructions in the data flow. 
    //
    getValueAt(addr)
    {
        var basicBlock = this.__findBasicBlock(this.__address);
        return basicBlock.Instructions.getValueAt(addr);
    }
}

// __getDisassemblyInfo:
//
// Gets information about where to disassemble for the data flow.  From the given address, this attempts
// to go back and find the start of the function to walk its dataflow.
//
function __getDisassemblyInfo(instrAddr)
{
    // 
    // If there is no specified address, grab IP.
    // @TODO: This should *NOT* directly reference RIP.  The stack frame should have an abstract IP/SP/FP
    //
    if (instrAddr === undefined)
    {
        if (__diag(5))
        {
            host.diagnostics.debugLog("Override to IP, instrAddr\n");
        }
        instrAddr = host.currentThread.Registers.User.rip;
    }

    //
    // If we can get the disassembly info from the new host.getModuleContainingSymbol, do so
    //
    var func;
    try
    {
        func = host.getModuleContainingSymbol(instrAddr);
    }
    catch(exc)
    {
    }

    if (func === undefined)
    {
        //
        // There should be a better way of doing this.  We should also use address instead!
        //
        var frame = host.currentThread.Stack.Frames[0];
        var frameStr = frame.toString();

        //
        // MODULE!NAME + OFFSET
        //
        var idx = frameStr.indexOf('+');
        if (idx != -1)
        {
            frameStr = frameStr.substr(0, idx).trim();
        }

        //
        // MODULE!NAME
        //
        var bangIdx = frameStr.indexOf('!');
        if (idx == -1)
        {
            throw new Error("Unable to find function name to disassemble");
        }

        var moduleName = frameStr.substr(0, bangIdx);
        var funcName = frameStr.substr(bangIdx + 1);

        if (__diag(2))
        {
            host.diagnostics.debugLog("ModuleName = '", moduleName, "'; funcName = '", funcName, "'\n");
        }

        func = host.getModuleSymbol(moduleName, funcName);
    }

    return { function: func, address: instrAddr };
}

// __CodeExtension:
//
// Provides an extension on Debugger.Utility.Code
//
class __CodeExtension
{
    TraceDataFlow(address)
    {
        var disassemblyInfo = __getDisassemblyInfo(address);
        var disassembler = host.namespace.Debugger.Utility.Code.CreateDisassembler();
        var funcDisassembly = disassembler.DisassembleFunction(disassemblyInfo.function, true);
        return new __TraceDataFlow(disassembler, funcDisassembly, disassemblyInfo.address);
    }
}

// __traceDataFlow:
//
// Function alias for !dflow
//
function __traceDataFlow(address)
{
    return host.namespace.Debugger.Utility.Code.TraceDataFlow(address);
}

// __disassembleCode:
//
// Function alias for !dis
//
function __disassembleCode(addressObj)
{
    var dbg = host.namespace.Debugger;

    if (addressObj === undefined)
    {
        //
        // @TODO:
        // This is *NOT* generic.  This is *DBGENG* specific.  We should get an IP from the stack.
        //
        addressObj = dbg.State.PseudoRegisters.RegisterAliases.ip.address;
    }

    return dbg.Utility.Code.CreateDisassembler().DisassembleInstructions(addressObj);
}

// __InstructionExtension:
//
// Provides an extension on an instruction
//
class __InstructionExtension
{
    get SourceDataFlow()
    {
        return __traceDataFlow(this.Address);
    }
}

// initializeScript:
//
// Initializes our script.  Registers our extensions and !dflow alias.
//
function initializeScript()
{
    return [new host.apiVersionSupport(1, 2),
            new host.namespacePropertyParent(__CodeExtension, "Debugger.Models.Utility", "Debugger.Models.Utility.Code", "Code"),
            new host.namedModelParent(__InstructionExtension, "Debugger.Models.Utility.Code.Instruction"),
            new host.functionAlias(__traceDataFlow, "dflow"),
            new host.functionAlias(__disassembleCode, "dis")];
}

// SIG // Begin signature block
// SIG // MIImTQYJKoZIhvcNAQcCoIImPjCCJjoCAQExDzANBglg
// SIG // hkgBZQMEAgEFADB3BgorBgEEAYI3AgEEoGkwZzAyBgor
// SIG // BgEEAYI3AgEeMCQCAQEEEBDgyQbOONQRoqMAEEvTUJAC
// SIG // AQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQg
// SIG // 8Vd5mJ3w6q+ClnHrnQIoaqCXDHQ0K4ZNgLaaX8x0Gjag
// SIG // ggtnMIIE7zCCA9egAwIBAgITMwAABae4j/uXXTWE7AAA
// SIG // AAAFpzANBgkqhkiG9w0BAQsFADB+MQswCQYDVQQGEwJV
// SIG // UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
// SIG // UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
// SIG // cmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQgQ29kZSBT
// SIG // aWduaW5nIFBDQSAyMDEwMB4XDTI0MDgyMjE5MjU1N1oX
// SIG // DTI1MDcwNTE5MjU1N1owdDELMAkGA1UEBhMCVVMxEzAR
// SIG // BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
// SIG // bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
// SIG // bjEeMBwGA1UEAxMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
// SIG // MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
// SIG // lhpUyo2LetKwfKDcj1iVBkFdjRsJUVyiYN+POKtpyYr/
// SIG // fha8/enxqF5W5SHid8akMRKAhA2I422ApYMd9TGXKEai
// SIG // Q9LCozbWAygNDYknTiULrd/hzdK0se+MqqGwwT/ACgMl
// SIG // gDWYrVEB5zx9RJE1zHUZZyZw9UbRZYzGDiZ68X6qwHbT
// SIG // TcVNaSGGJmOqA/HcnvNYvUR8UiRhIHzJxCKZ/9ckpIpE
// SIG // 1fjThxY9UB+/kh2VmDXHYC+PEEmtYwt9AIujCi4fdRTr
// SIG // ArLjVNHEwus+kJD+dZfXVPAfsZ72Wtv1s7yYQcmZ410v
// SIG // rVXjdigeRKdLHjrbhcLyOiqDl6xEygg4OwIDAQABo4IB
// SIG // bjCCAWowHwYDVR0lBBgwFgYKKwYBBAGCNz0GAQYIKwYB
// SIG // BQUHAwMwHQYDVR0OBBYEFFIVus1TcIc5i27HKM2KacHf
// SIG // HysSMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQLExVNaWNy
// SIG // b3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDg2
// SIG // NSs1MDI3MDMwHwYDVR0jBBgwFoAU5vxfe7siAFjkck61
// SIG // 9CF0IzLm76wwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDov
// SIG // L2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVj
// SIG // dHMvTWljQ29kU2lnUENBXzIwMTAtMDctMDYuY3JsMFoG
// SIG // CCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDov
// SIG // L3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWND
// SIG // b2RTaWdQQ0FfMjAxMC0wNy0wNi5jcnQwDAYDVR0TAQH/
// SIG // BAIwADANBgkqhkiG9w0BAQsFAAOCAQEAJdXECEPhQ/7m
// SIG // 2liIjIPMELRMd0pLEOa+qgIH3qznuk2eW5k3DI9lVJBy
// SIG // 675oUnKEXvaUPwqsGeu+mLjPdLYqj6zA41zvJCwgPpE3
// SIG // g2aCkC9DCNkoWw4V6wyLLovYRjYXfD8Bk1kJLJ6DuB8a
// SIG // hhtjH4qrJzoDKPR4ppkxdvx9Vy3P4Nkz6RfBslwHKO5I
// SIG // XIeJdYSCKZlRGTemRQpNv5Dn+5trApfIefgVkA5kmhAr
// SIG // SNsXOUi26qLdYrFrxYhEbWsPcUG99TFmGrNpdv13XGx+
// SIG // 0BWKSqRuHQ2YSiHZUVZmKVMkWjTmVjcDXOxum8yiAtxw
// SIG // BhTiBHOGg0Ltsk/6tMie1jCCBnAwggRYoAMCAQICCmEM
// SIG // UkwAAAAAAAMwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
// SIG // BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
// SIG // VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
// SIG // Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
// SIG // b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
// SIG // DTEwMDcwNjIwNDAxN1oXDTI1MDcwNjIwNTAxN1owfjEL
// SIG // MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
// SIG // EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
// SIG // c29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
// SIG // b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMDCCASIwDQYJ
// SIG // KoZIhvcNAQEBBQADggEPADCCAQoCggEBAOkOZFB5Z7XE
// SIG // 4/0JAEyelKz3VmjqRNjPxVhPqaV2fG1FutM5krSkHvn5
// SIG // ZYLkF9KP/UScCOhlk84sVYS/fQjjLiuoQSsYt6JLbklM
// SIG // axUH3tHSwokecZTNtX9LtK8I2MyI1msXlDqTziY/7Ob+
// SIG // NJhX1R1dSfayKi7VhbtZP/iQtCuDdMorsztG4/BGScEX
// SIG // ZlTJHL0dxFViV3L4Z7klIDTeXaallV6rKIDN1bKe5QO1
// SIG // Y9OyFMjByIomCll/B+z/Du2AEjVMEqa+Ulv1ptrgiwtI
// SIG // d9aFR9UQucboqu6Lai0FXGDGtCpbnCMcX0XjGhQebzfL
// SIG // GTOAaolNo2pmY3iT1TDPlR8CAwEAAaOCAeMwggHfMBAG
// SIG // CSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBTm/F97uyIA
// SIG // WORyTrX0IXQjMubvrDAZBgkrBgEEAYI3FAIEDB4KAFMA
// SIG // dQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUw
// SIG // AwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
// SIG // zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3Js
// SIG // Lm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
// SIG // aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
// SIG // BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
// SIG // Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0Nl
// SIG // ckF1dF8yMDEwLTA2LTIzLmNydDCBnQYDVR0gBIGVMIGS
// SIG // MIGPBgkrBgEEAYI3LgMwgYEwPQYIKwYBBQUHAgEWMWh0
// SIG // dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9QS0kvZG9jcy9D
// SIG // UFMvZGVmYXVsdC5odG0wQAYIKwYBBQUHAgIwNB4yIB0A
// SIG // TABlAGcAYQBsAF8AUABvAGwAaQBjAHkAXwBTAHQAYQB0
// SIG // AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIB
// SIG // ABp071dPKXvEFoV4uFDTIvwJnayCl/g0/yosl5US5eS/
// SIG // z7+TyOM0qduBuNweAL7SNW+v5X95lXflAtTx69jNTh4b
// SIG // YaLCWiMa8IyoYlFFZwjjPzwek/gwhRfIOUCm1w6zISnl
// SIG // paFpjCKTzHSY56FHQ/JTrMAPMGl//tIlIG1vYdPfB9XZ
// SIG // cgAsaYZ2PVHbpjlIyTdhbQfdUxnLp9Zhwr/ig6sP4Gub
// SIG // ldZ9KFGwiUpRpJpsyLcfShoOaanX3MF+0Ulwqratu3JH
// SIG // Yxf6ptaipobsqBBEm2O2smmJBsdGhnoYP+jFHSHVe/kC
// SIG // Iy3FQcu/HUzIFu+xnH/8IktJim4V46Z/dlvRU3mRhZ3V
// SIG // 0ts9czXzPK5UslJHasCqE5XSjhHamWdeMoz7N4XR3HWF
// SIG // nIfGWleFwr/dDY+Mmy3rtO7PJ9O1Xmn6pBYEAackZ3PP
// SIG // TU+23gVWl3r36VJN9HcFT4XG2Avxju1CCdENduMjVngi
// SIG // Jja+yrGMbqod5IXaRzNij6TJkTNfcR5Ar5hlySLoQiEl
// SIG // ihwtYNk3iUGJKhYP12E8lGhgUu/WR5mggEDuFYF3Ppzg
// SIG // UxgaUB04lZseZjMTJzkXeIc2zk7DX7L1PUdTtuDl2wth
// SIG // PSrXkizON1o+QEIxpB8QCMJWnL8kXVECnWp50hfT2sGU
// SIG // jgd7JXFEqwZq5tTG3yOalnXFMYIaPjCCGjoCAQEwgZUw
// SIG // fjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
// SIG // b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
// SIG // Y3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWlj
// SIG // cm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMAITMwAA
// SIG // Bae4j/uXXTWE7AAAAAAFpzANBglghkgBZQMEAgEFAKCB
// SIG // xjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
// SIG // BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG
// SIG // 9w0BCQQxIgQgohfhR3HhTgB0yf0ye4cb5ufm23Z7jaz/
// SIG // DkRz8NyYF4wwWgYKKwYBBAGCNwIBDDFMMEqgJIAiAE0A
// SIG // aQBjAHIAbwBzAG8AZgB0ACAAVwBpAG4AZABvAHcAc6Ei
// SIG // gCBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vd2luZG93
// SIG // czANBgkqhkiG9w0BAQEFAASCAQAk/az+PIYkbyw9/NN4
// SIG // VkEyy+XC+SrKtPNDJHRveZRlA6/klwJDuSsNiNvyRxy+
// SIG // BRRvfrbmty3Nzo71QC3Jh0fPQAPjSk+dVnLTWRx4M26f
// SIG // gDhzFlgkOxewMLmGCxzpwa76udsaLyakmkSg1Nf1DBoq
// SIG // J7rWs/c+F8McKxyPMIMNr349lpAL0P2lgsMySCCrlciG
// SIG // svC48OUV7tNXm3YplxHnHp+h3KwNEJG/DRTJTo2Hpdnf
// SIG // RqwrY+BH7T1ErhB6simWNJDUMP62vj85avu4pv267JT8
// SIG // Hj4gKaPaHN0T01b/sMcG1mp2ktPdWPvenG1OKU2xMaag
// SIG // Vz8LVtUIolJ4Scb1oYIXsDCCF6wGCisGAQQBgjcDAwEx
// SIG // ghecMIIXmAYJKoZIhvcNAQcCoIIXiTCCF4UCAQMxDzAN
// SIG // BglghkgBZQMEAgEFADCCAVoGCyqGSIb3DQEJEAEEoIIB
// SIG // SQSCAUUwggFBAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZI
// SIG // AWUDBAIBBQAEIOeeHXEdjJZnSxOFEspQ7P0MaeG0tMN/
// SIG // lhmjVvTVJwY+AgZm60yPRkUYEzIwMjQxMTE2MDQzNzAw
// SIG // LjU3N1owBIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVT
// SIG // MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
// SIG // ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
// SIG // YXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
// SIG // IE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNo
// SIG // aWVsZCBUU1MgRVNOOjRDMUEtMDVFMC1EOTQ3MSUwIwYD
// SIG // VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNl
// SIG // oIIR/jCCBygwggUQoAMCAQICEzMAAAH/Ejh898Fl1qEA
// SIG // AQAAAf8wDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMC
// SIG // VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
// SIG // B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
// SIG // b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
// SIG // U3RhbXAgUENBIDIwMTAwHhcNMjQwNzI1MTgzMTE5WhcN
// SIG // MjUxMDIyMTgzMTE5WjCB0zELMAkGA1UEBhMCVVMxEzAR
// SIG // BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
// SIG // bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
// SIG // bjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3Bl
// SIG // cmF0aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5uU2hpZWxk
// SIG // IFRTUyBFU046NEMxQS0wNUUwLUQ5NDcxJTAjBgNVBAMT
// SIG // HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
// SIG // MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDJ6JXS
// SIG // kHtuDz+pz+aSIN0lefMlY9iCT2ZMZ4jenNCmzKtElERZ
// SIG // wpgd3/11v6DfPh1ThUKQBkReq+TE/lA1O0Ebkil7GmmH
// SIG // g+FuIkrC9f5RLgqRIWF/XB+UMBjW270JCqGHF8cVXu+G
// SIG // 2aocsIKYPGFk+YIGH39d8UlAhTBVlHxG1SSDOY31uZaJ
// SIG // iB9fRH5sMCedxR22nXGMaYKl0EzKCT8rSHdtRNTNAdvi
// SIG // Q9/bKWQo+hYVifYY1iBbDw8YFQ7S9MwqNgPqkt4E/SFk
// SIG // OHk/d/jGEYubrH3zG4hCn9EWfMFuC2HJJcaX41PVxkCo
// SIG // bISFPsvRJ1HupCW/mnAM16tsrdhIQMqTewOH1LrSEsk2
// SIG // o/vWIcqQbXvkcDKDrOYTmnd842v398gSk8CULxiKzFdo
// SIG // ZfhGkMFhUqkaPQUJnCKyJmzGbRf3DplKTw45d/wnFNhY
// SIG // ip9G5bN1SKvRneOI461oOrtd3KkHiBmuGv3Qpw9MNHC/
// SIG // LrTOtBxr/UPUns9AkAk5tuJpuiLXa6xXxrG2VP90J48L
// SIG // id1wVxqvW/5+cKWGz27cWfouQcNFl83OFeAsMTBvp0Dj
// SIG // Lezob6BDfmj3SPaLpqZprwmxX9wIX6INIbMDFljWxDWa
// SIG // t0ybPF9bNc3qw8kzLj212xZMiBlZU5JL25QeFJiRuAzG
// SIG // ct6Ipd4HkwH1Axw5JwIDAQABo4IBSTCCAUUwHQYDVR0O
// SIG // BBYEFMP6leT+tP93sT/RATuEfTDP7pRhMB8GA1UdIwQY
// SIG // MBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRY
// SIG // MFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
// SIG // bS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3Rh
// SIG // bXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcB
// SIG // AQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWlj
// SIG // cm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
// SIG // JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0
// SIG // MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYB
// SIG // BQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEB
// SIG // CwUAA4ICAQA5I03kykuLK6ebzrp+tYiLSF1rMo0uBGnd
// SIG // Zk9+FiA8Lcr8M0zMuWJhBQCnpa2CiUitq2K9eM4bWUiN
// SIG // rIb2vp7DgfWfldl0N8nXYMuOilqnl7WJT9iTR660/J86
// SIG // J699uwjNOT8bnX66JQmTvvadXNq7qEjYobIYEk68BsBU
// SIG // VHSDymlnAuCFPjPeaQZmOr87hn89yZUa2MamzZMK0jit
// SIG // mM81bw7hz/holGZhD811b3UlGs5dGnJetMpQ97eQ3w3n
// SIG // qOmX2Si0uF293z1Fs6wk1/ZfOpsBXteNXhxoKCUDZu3M
// SIG // PFzJ9/BeEu70cxTd0thMAj3WBM1QXsED2rUS9KUIoqU3
// SIG // w3XRjiJTSfIiR+lHFjIBtHKrlA9g8kcYDRPLQ8PzdoK3
// SIG // v1FrQh0MgxK7BeWlSfIjLHCsPKWB84bLKxYHBD+Ozbj1
// SIG // upA5g92nI52BF7y1d0auAOgF65U4r5xEKVemKY1jCvrW
// SIG // hnb+Q8zNWvNFRgyQFd71ap1J7OHy3K266VhhxEr3mqKE
// SIG // XSKtCzr9Y5AmW1Bfv2XMVcT0UWWf0yLHRqz4Lgc/N35L
// SIG // RsE3cDddFE7AC/TXogK5PyFjUifJbuPBWY346RDXN6Lr
// SIG // outTlG0DPSdPHHk54/KOdNoi1NJjg4a4ZTVJdofj0lI/
// SIG // e3zIZgD++ittbhWd54PvbUWDBolOgcWQ4jCCB3EwggVZ
// SIG // oAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZI
// SIG // hvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
// SIG // EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
// SIG // HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
// SIG // BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
// SIG // IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoX
// SIG // DTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzAR
// SIG // BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
// SIG // bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
// SIG // bjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
// SIG // UENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
// SIG // ggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH
// SIG // 0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVri
// SIG // fkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsH
// SIG // FPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrE
// SIG // qv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rbo
// SIG // YiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBp
// SIG // Dco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pG
// SIG // ve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
// SIG // lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
// SIG // EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
// SIG // Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269e
// SIG // wvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPK
// SIG // Z6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFd
// SIG // XzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxS
// SIG // UV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUY
// SIG // P3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB
// SIG // 3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEE
// SIG // AYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYD
// SIG // VR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1Ud
// SIG // IARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUH
// SIG // AgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
// SIG // cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAK
// SIG // BggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBi
// SIG // AEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
// SIG // /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
// SIG // xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
// SIG // Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNS
// SIG // b29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUH
// SIG // AQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1p
// SIG // Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1
// SIG // dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOC
// SIG // AgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4
// SIG // sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGU
// SIG // GCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ
// SIG // 7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f
// SIG // 8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfg
// SIG // QJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlS
// SIG // dYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDS
// SIG // PeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDF
// SIG // NLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
// SIG // bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
// SIG // ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
// SIG // AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0
// SIG // zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5
// SIG // m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGe
// SIG // Pu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3u
// SIG // gm2lBRDBcQZqELQdVTNYs6FwZvKhggNZMIICQQIBATCC
// SIG // AQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
// SIG // EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
// SIG // HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
// SIG // BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlv
// SIG // bnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1Mg
// SIG // RVNOOjRDMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNy
// SIG // b3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYF
// SIG // Kw4DAhoDFQCpE4xsxLwlxSVyc+TBEsVE9cWymaCBgzCB
// SIG // gKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
// SIG // aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
// SIG // ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
// SIG // HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0G
// SIG // CSqGSIb3DQEBCwUAAgUA6uI+JjAiGA8yMDI0MTExNTIx
// SIG // Mzk1MFoYDzIwMjQxMTE2MjEzOTUwWjB3MD0GCisGAQQB
// SIG // hFkKBAExLzAtMAoCBQDq4j4mAgEAMAoCAQACAhdjAgH/
// SIG // MAcCAQACAhMxMAoCBQDq44+mAgEAMDYGCisGAQQBhFkK
// SIG // BAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSCh
// SIG // CjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAEQD
// SIG // 8rvTHFlOj89MLU8axHsZxAlaTdft/7/r31BnQu3gW3vV
// SIG // R9j/nxBQPdMYwfog1ofBfW+/N2sDrsxz9wzx++4NsoRD
// SIG // yxR67diJKY3i9AnfUXxFpUSGpLmh4qQosQbqSdzvtBAn
// SIG // MQEwg7Rse+xxwe+ySGZBDh0XHpvwHoZYf4PYZ5weNYCL
// SIG // vPmIhyw4wLrs+qaFwjYNqGRMRPuCXFDJdtz24XZE2shY
// SIG // nCDa689ojayMmbi4yYHk4M4T+irYCGfosWuT8zLYRo3k
// SIG // nwG7HAAFxvU1V+7lp8iVwJ1u0K89acG1vhhaLLWiLnyk
// SIG // 3JnRIhrnjATHpCGPjpxwgcZ0iABf9RExggQNMIIECQIB
// SIG // ATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
// SIG // aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
// SIG // ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
// SIG // Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAIT
// SIG // MwAAAf8SOHz3wWXWoQABAAAB/zANBglghkgBZQMEAgEF
// SIG // AKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEE
// SIG // MC8GCSqGSIb3DQEJBDEiBCDYrCadp4wIboKmNuC3FY8y
// SIG // wrBgBET2QSpCT395om7LHTCB+gYLKoZIhvcNAQkQAi8x
// SIG // geowgecwgeQwgb0EIOQy777JAndprJwi4xPq8Dsk24xp
// SIG // U4jeoONIRXy6nKf9MIGYMIGApH4wfDELMAkGA1UEBhMC
// SIG // VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
// SIG // B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
// SIG // b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
// SIG // U3RhbXAgUENBIDIwMTACEzMAAAH/Ejh898Fl1qEAAQAA
// SIG // Af8wIgQgk8sOMPOKbTKhr9HTeQd0W4rTyLBB76gYRTNZ
// SIG // pkn+St8wDQYJKoZIhvcNAQELBQAEggIAX2h562VbcjqA
// SIG // BygKHaxQfU+AgKuXYaAQehRTnEZfMkUgtkj9w6g5Tzcz
// SIG // C2bTwx/f9vOSd7I9Aeg/nKtwn7REuLA23O8x4kAfXRW2
// SIG // EV77u8um+6Aa+A4xh0jL3XIBYDbd4ocGfYsU9/qoVBB3
// SIG // MrcKsp7nNNQiJl/dcMmRmLN3Ux5KOJaJJxF+UOGlYhuX
// SIG // 6ByJCayVStiL9bnIU3VoXaP3r1xtNYCq4K2eCsyIxW5z
// SIG // Wq/Tdz/45K1V2Djb73qsHv+Dk6QaPUzLjj/5Hm9bYPeW
// SIG // 3FFEhVoAzsmJFyRh8iZjFgVImfN5YqUTTDjkAn588pEN
// SIG // eNvXbFISajo5IJSwCI8omWbL3UvNeDiSgZCQZdJhrBn2
// SIG // swIg/9+X/3zPNSYQF1H8tXqFFL+AaRQF94QB8YFzv0sI
// SIG // jk3E72VEASrDUOYLcZKGZQAemRfD8x7wgArKLYv/myQI
// SIG // Se+WZscUP1HZkz/9WU8XMgJ5nhxd00XNYGfUccbMcT7k
// SIG // TqegRAyq+xZJ67RLS7dNCezOZs3b97vQbQDg6VKkh0b6
// SIG // NQjJyRkgiTS8jSCSToleuK6OiUUcSO4QFKvxgNf3ySvA
// SIG // 67JLLknb1Zg+uZa8keQ1cqnUsqIo6HOuKw7LFMjaR8+N
// SIG // l+DGYg9abGgb4hcgBHpY2zLWRHXTcTbekUEPK1fgFte4
// SIG // LMdAN0Y6bZA=
// SIG // End signature block
