// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*
@title KipuBank
@notice Este contrato representa un banco personal.
*/

/*///////////////////////
        Libraries
///////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


/*///////////////////////
        Interfaces
///////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

contract KipuBank is AccessControl{
    /*///////////////////////
        Type declarations
    ///////////////////////*/
    using SafeERC20 for IERC20;
    struct tokenERC20{
        bool isSupported;
        IERC20  token;
    }
    
    /*///////////////////////
            Variables
    ///////////////////////*/
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE"); //@notice Crea el rol de Administrador del banco. 

    AggregatorV3Interface private s_feeds;//0x694AA1769357215DE4FAC081bf1f309aDC325306 Ethereum ETH/USD
    IUniswapV2Router02 immutable i_router;

    uint256 constant DECIMAL_FACTOR = 1 * 10 ** 20; //@notice Constante para almacenar el factor de decimales
    uint16 constant ORACLE_HEARTBEAT = 3600; //@notice Constante para almacenar el latido (heartbeat) del Data Feed

    mapping (address token => tokenERC20) private s_supportedTokens; //@notice Son los ERC20 aceptados por el banco. Los determina el/los admin/s.  
    mapping (address user =>  mapping (address token => uint256 saldo)) private s_users; //@notice Mapa que almacena los usuarios con el saldo de sus tokens

    uint256 private immutable i_maxTransaction = 1000000000000000000; //@notice Determina el maximo por transaccion.
    uint256 private immutable i_bankCap; //@notice Determina el maximo de deposito en el banco. Esto ahora queda determinado en USD. 
    uint256 private depositsCount; //@notice Numero de depositos realizados
    uint256 private withdrawalsCount; //@notice Numero de retiros realizados
    uint256 private balanceUSDC; //@notice Balance total expresado en USDC

    

    /*/////////////////////
            Events
    /////////////////////*/

    //@notice Evento que se lanza cuando se realiza correctamente un deposito.
    event KipuBank_DepositSuccessful(uint256);
    //@notice Evento que se lanza cuando se realiza correctamente un retiro.
    event KipuBank_WithdrawSuccessful(uint256);
    //@ Evento que se lanza cuando un token nuevo se agrega correctamente.
    event KipuBank_TokenAddedSuccessfully(address);
    //@ Evento que se lanza cuando un token nuevo se agrega correctamente.
    event KipuBank_TokenDeletedSuccessfully(address);
    //@ Evento que se lanza cuando se actualiza el feed de Chainlink
    event KipuBank_ChainlinkFeedUpdated(address);
    
    /*/////////////////////
            Errors
    /////////////////////*/

    //@notice Error que se lanza cuando se excede el bankCap
    error KipuBank_DepositAmountExceeded(uint256);
    //@notice Error que se lanza cuando se realiza un deposito invalido
    error KipuBank_InvalidAmount(uint256);
    //@notice Error que se lanza cuando se excede el monto maximo por transaccion
    error KipuBank_TransactionAmountExceeded(uint256,uint256);
    //@notice Error que se lanza cuando no hay saldo disponsible
    error KipuBank_InsufficientBalance(uint256);
    //@notice Error que se lanza cuando no se puede transferir ETH
    error KipuBank_TransferFailed(bytes);
    //@notice Error que se lanza si quien quiere ejecutar una funcion no tiene un rol valido.
    error KipuBank_CallerNotAdmin(address);
    //@notice Error que se lanza cuando el token no es aceptado.
    error KipuBank_TokenNotSupported(address);
    //@notice error emitido cuando el retorno del oráculo es incorrecto
    error KipuBank_OracleCompromised();
    //@notice error emitido cuando la última actualización del oráculo supera el heartbeat
    error KipuBank_StalePrice();

    /*//////////////////////////
            Modifiers
    //////////////////////////*/

    /*
     @notice valida que el deposito se pueda realizar
    */
    modifier validateDepositETH(){
        if(msg.value <= 0) revert KipuBank_InvalidAmount(msg.value); 
        if(convertEthInUSD(msg.value)+balanceUSDC > i_bankCap) revert KipuBank_DepositAmountExceeded(balanceUSDC);
        if(msg.value > i_maxTransaction) revert KipuBank_TransactionAmountExceeded(msg.value,i_maxTransaction);
        _;
    }   

    /*
     @notice valida que el retiro se pueda realizar
     @param _amount es el monto que se quiere retirar
    */
    modifier validateWithdrawal(uint256 _amount, address _token){
        if(!s_supportedTokens[_token].isSupported) revert KipuBank_TokenNotSupported(_token);
        if(_amount > s_users[msg.sender][_token]) revert KipuBank_InsufficientBalance(s_users[msg.sender][_token]);
        if(_amount > i_maxTransaction) revert KipuBank_TransactionAmountExceeded(_amount,i_maxTransaction);
        if(_amount <= 0) revert KipuBank_InvalidAmount(_amount); 
        _;
    }

    /*
     @notice Valida que se pueda depositar ese token ERC20
    */
    modifier validateDepositERC20(address _token){
        if(!s_supportedTokens[_token].isSupported) revert KipuBank_TokenNotSupported(_token);
        _;
    }

    /*
     @notice valida que el llamador sea un admin
    */
    modifier isAdmin(){
        if(!hasRole(ADMIN_ROLE,msg.sender)){
            revert KipuBank_CallerNotAdmin(msg.sender);
        }
        _;
    }

    /*
     @notice valida que el token sea aceptado
    */
    modifier tokenIsSupported(address _token){
        if(!s_supportedTokens[_token].isSupported) revert KipuBank_TokenNotSupported(_token);
        _;
    }

    /*/////////////////////
            Constructor
    /////////////////////*/

    /*
     @notice Constructor del contrato
     @param _amountBankCap es el monto maximo que puede almacenar el banco
    */
    constructor(uint256 _amountBankCap, address _admin, address _feed, address _router){
        balanceUSDC = 0;
        depositsCount = 0;
        withdrawalsCount = 0;
        _grantRole(ADMIN_ROLE, _admin);
        s_supportedTokens[address(0)].isSupported = true;
        s_feeds = AggregatorV3Interface(_feed);
        i_router = IUniswapV2Router02(_router);
        i_bankCap = convertEthInUSD(_amountBankCap);      
    }

    /*/////////////////////
            Functions
    /////////////////////*/
    
    /*///// Funciones de ETH ////////////*/
    receive() external payable {
        _depositETHLogic();
    }

    fallback() external payable {
        _depositETHLogic();
     }
    
    /*
     @notice Realiza el deposito
    */
    function depositETH()external payable{
        _depositETHLogic();
    }

    /*
     @notice Realiza la logica del deposito
    */
    function _depositETHLogic() private validateDepositETH(){
        s_users[msg.sender][address(0)] += msg.value;
        balanceUSDC += convertEthInUSD(msg.value);
        depositsCount++;
        emit KipuBank_DepositSuccessful(msg.value);
    }

    /*
     @notice Realiza el retiro
     @param _amount es el monto que se quiere retirar
    */
    function withdrawETH(uint256 _amount) external validateWithdrawal(_amount, address(0)){
        s_users[msg.sender][address(0)] -= _amount;
        balanceUSDC -= convertEthInUSD(_amount);
        _transferETH(payable(msg.sender),_amount);
        withdrawalsCount++;
        emit KipuBank_WithdrawSuccessful(_amount);
    }

    /*///// Funciones Tokens ERC20 ////////////*/

    /*
     @notice Funcion para depositar tokens ERC20
     @param _amount es el monto que se quiere depositar
     @param _token es el token que se quiere depositar
    */
    function depositERC20(uint256 _amount, address _token)external tokenIsSupported(_token){
        s_users[msg.sender][_token] += _amount;
        depositsCount++;
        //Estimo cantidad
        //Sumo BalanceUSDC

        emit KipuBank_DepositSuccessful(_amount);
        
        s_supportedTokens[_token].token.safeTransferFrom(msg.sender,address(this),_amount);
        //Swap: ERC20 -> USDC
    }

    /*
     @notice Funcion para retirar tokens ERC20
     @param _amount es el monto que se quiere retirar
     @param _token es el token que se quiere retirar
    */
    function withdrawERC20(uint256 _amount, address _token)external validateWithdrawal(_amount, _token){
        s_users[msg.sender][_token] -= _amount;
        withdrawalsCount++;
        //Resto balance USDC


        emit KipuBank_WithdrawSuccessful(_amount);  
        //Swap USDC -> ERC20
        s_supportedTokens[_token].token.safeTransfer(msg.sender,_amount);
    }
    
    /*///// Funciones de Swap ///////////*/
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data)external{

    }


    /*///// Funciones de Admin ////////////*/
    /*
     @notice Agrega un nuevo admin. Solo puede ser agregado por otro admin.
    */
    function addAdmin() external isAdmin(){
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /*
     @notice Agrega un nuevo token. Solo puede ser agregado por un admin.
     @param _newToken es el nuevo token que se quiere agregar.
    */
    function addSupportedToken(address _newToken) external isAdmin(){
        s_supportedTokens[_newToken].isSupported = true;
        s_supportedTokens[_newToken].token = IERC20(_newToken);
        emit KipuBank_TokenAddedSuccessfully(_newToken);
    }

    /*
     @notice Elimina un token de la lista de tokens soportados. Solo puede ser eliminado por un admin.
     @param _token es el token que se quiere eliminar.
    */
    function deleteSupportedToken(address _token) external isAdmin() tokenIsSupported(_token){
        s_supportedTokens[_token].isSupported = false;
        emit KipuBank_TokenDeletedSuccessfully(_token);
    }

    /**
     * @notice función para actualizar el Chainlink Price Feed
     * @param _feed la nueva dirección del Price Feed
     * @dev debe ser llamada solo por el propietario
     */
    function setFeeds(address _feed) external isAdmin(){
        s_feeds = AggregatorV3Interface(_feed);

        emit KipuBank_ChainlinkFeedUpdated(_feed);
    }

    /*/////////////////////////
            Internal
    /////////////////////////*/

    /**
     * @notice función interna para realizar la conversión de decimales de ETH a USDC
     * @param _ethAmount la cantidad de ETH a ser convertida
     * @return convertedAmount_ el resultado del cálculo.
     */
    function convertEthInUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_ethAmount * chainlinkFeed()) / DECIMAL_FACTOR;
    }

        /**
     * @notice función para consultar el precio en USD del ETH
     * @return ethUSDPrice_ el precio provisto por el oráculo.
     * @dev esta es una implementación simplificada, y no sigue completamente las buenas prácticas
     */
    function chainlinkFeed() internal view returns (uint256 ethUSDPrice_) {
        (, int256 ethUSDPrice,, uint256 updatedAt,) = s_feeds.latestRoundData();

        if (ethUSDPrice == 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT)revert KipuBank_StalePrice();

        ethUSDPrice_ = uint256(ethUSDPrice);
    }

    /*/////////////////////////
            Private
    /////////////////////////*/
    /*
     @notice ejecuta la transferencia de ETH a la address
     @param _to es la address a la cual se le transfiere el ETH
    */
    function _transferETH(address _to,uint256 _amount) private{
        (bool isSuccessful, bytes memory error) = _to.call{value: _amount}("");
        if(!isSuccessful) revert KipuBank_TransferFailed(error);
    }

    /*/////////////////////////
               View
    /////////////////////////*/
    /*
     @notice Funcion que devuelve el saldo de una cuenta.
     @return _balance es el saldo de la cuenta.
    */
    function consultarSaldoETH()external view returns (uint256 _balance){
        _balance = s_users[msg.sender][address(0)];
    }

    /*
     @notice Funcion que devuelve el saldo de una cuenta.
     @return _balance es el saldo de la cuenta.
    */
    function consultarSaldoERC20(address _token)external view tokenIsSupported(_token) returns (uint256 _balance){
        _balance = s_users[msg.sender][_token];
    }

}