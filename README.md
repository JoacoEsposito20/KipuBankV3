# KipuBankV3
Este contrato permite al usuario gestionar sus tokens nativos (ETH) y otros tokens fungibles en una boveda personal.
Es posible *depositar* y *retirar* los tokens y *consultar* el saldo disponible en la boveda.
Se utilizan buenas practicas de seguridad para garantizar que solo el propietario de los tokens tenga acceso a los mismos.  

En esta nueva versión se incluye que, dentro del banco, todos los tokens son convertidos a USDC utilizando UniswapV2.
Para el manejo de tokens ERC20 y la gestión del control de acceso se utilizaron librerias de OpenZeppelin, referentes en la seguridad de aplicaciones en blockchain y contratos inteligentes.
Se agrego ademas la libreria ReentrancyGuard de OpenZeppelin para mejora de la seguridad.

## Instrucciones de despligue - Foundry.
Para el desarrollo de esta versión se utilizó Foundry. 
Se debe compilar el contrato KipuBankV3.sol utilizando la herramienta **Forge** de Foundry mediante el comando.
    forge build
El comando debe ejecutarse en el directorio raiz del proyecto.
   
Para el despliegue se utiliza el siguiente comando:
    forge create --rpc-url $RPC_URL \
                 --private-key $PRIVATE_KEY \
                 src/KipuBankV3.sol:KipuBankV3 \
                 --constructor-args [ARGUMENTOS]

## Cómo interactuar con el contrato. 
- Restricciones: 
El banco cuenta con una cantidad máxima de transacción permitida y una cantidad máxima de saldo depositado en todo el banco que se determinan al momento del despliegue del contrato.

### Funciones:
- *depositETH*: Permite depositar ETH en la boveda personal del usuario a traves de una transacción.
- *withdrawETH*: Permite retirar el ETH de la boveda personal. Se le pasa por parametro el monto que se quiere retirar y este es transferido a la dirección del usuario luego de validar que la transferencia sea posible. 
- *consultarSaldoETH*: Permite consultar el saldo de la boveda personal del usuario. 

- *depositERC20*: Permite depositar tokens ERC20 en la boveda personal del usuario.
- *withdrawERC20*: Permite retirar tokens ERC20 de la boveda personal. Se le pasa por parametro el monto que se quiere retirar y este es transferido a la dirección del usuario luego de validar que la transferencia sea posible.
- *consultarSaldoERC20*: Permite consultar el saldo, del ERC20 indicado, de la boveda personal del usuario.

Teniendo en cuenta que ahora todos los tokens son convertidos a USDC, se puede estimar que cantidad de tokens recibira el cliente en relación al valor de USDC en ese momento. 
- *estimateWithdrawETH*: Devuelve la cantidad de ETH que recibirá el cliente en relación a los USDC ingresados.
- *estimateWithdrawERC20*: Devuelve la cantidad de ERC20 que recibirá el cliente en relación a los USDC ingresados.

