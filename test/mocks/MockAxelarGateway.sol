// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IExposedExecute {
    function exposed_execute(
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}

contract MockAxelarGasService {
    function payNativeGasForContractCall(
        address,
        string calldata,
        string calldata,
        bytes calldata,
        address
    ) external payable {}
}

contract MockAxelarGateway {
    function simulateExecute(
        address target,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        try IExposedExecute(target).exposed_execute(sourceChain, sourceAddress, payload) {
        } catch (bytes memory ret) {
            if (ret.length > 0) {
                assembly {
                    revert(add(32, ret), mload(ret))
                }
            } else {
                revert("MockAxelarGateway: call failed");
            }
        }
    }
}