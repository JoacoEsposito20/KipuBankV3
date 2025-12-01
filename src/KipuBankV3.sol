// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*
@title KipuBankV3
@notice Banco DeFi avanzado que acepta cualquier token Uniswap V2 y lo convierte a USDC.
*/

/*///////////////////////
        Libraries
///////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*///////////////////////
        Interfaces
///////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    /*///////////////////////
        Type declarations
    ///////////////////////*/
    using SafeERC20 for IERC20;

    /*///////////////////////
            Variables
    ///////////////////////*/
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IUniswapV2Router02 public immutable i_router;
    IUniswapV2Factory public immutable i_uniswapFactory;
    address public immutable i_usdcToken;

    uint256 private constant SLIPPAGE_TOLERANCE = 98; // 2% slippage tolerance
    uint256 private constant SLIPPAGE_DENOMINATOR = 100;
    uint256 private constant SWAP_DEADLINE = 300; // 5 minutos

    uint256 public immutable i_maxTransaction;
    uint256 public immutable i_bankCap;

    uint256 private depositsCount;
    uint256 private withdrawalsCount;
    uint256 private balanceUSDC;

    mapping(address user => uint256 balance) private s_userBalances;

    /*/////////////////////
            Events
    /////////////////////*/
    event KipuBank_DepositSuccessful(address indexed user, uint256 usdcAmount);
    event KipuBank_WithdrawSuccessful(address indexed user, uint256 amount);
    event KipuBank_SwapExecuted(
        address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event KipuBank_AdminAdded(address indexed newAdmin);
    event KipuBank_EmergencyWithdraw(address indexed token, uint256 amount);

    /*/////////////////////
            Errors
    /////////////////////*/
    error KipuBank_DepositAmountExceeded(uint256 currentBalance, uint256 bankCap);
    error KipuBank_InvalidAmount(uint256 amount);
    error KipuBank_TransactionAmountExceeded(uint256 amount, uint256 maxTransaction);
    error KipuBank_InsufficientBalance(uint256 requested, uint256 available);
    error KipuBank_CallerNotAdmin(address caller);
    error KipuBank_InvalidAddress(address addr);
    error KipuBank_SwapFailed(string reason);
    error KipuBank_SlippageTooHigh(uint256 expected, uint256 minimum);
    error KipuBank_PairNotFound(address token);

    /*//////////////////////////
            Modifiers
    //////////////////////////*/

    modifier validateDeposit(uint256 _amount, address _token) {
        _validateDeposit(_amount, _token);
        _;
    }

    modifier validateWithdrawal(uint256 _amountUSDC) {
        _validateWithdrawal(_amountUSDC);
        _;
    }

    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) {
            revert KipuBank_CallerNotAdmin(msg.sender);
        }
        _;
    }

    /*/////////////////////
            Constructor
    /////////////////////*/

    /**
     * @notice Constructor del contrato KipuBankV3
     * @param _amountBankCap Capacidad maxima del banco en USDC (con decimales)
     * @param _maxTransaction Monto maximo por transacción
     * @param _admin Direccion del administrador inicial
     * @param _router Direccion del Uniswap V2 Router
     * @param _usdc Direccion del token USDC
     */
    constructor(uint256 _amountBankCap, uint256 _maxTransaction, address _admin, address _router, address _factory, address _usdc) {
        if (_admin == address(0) || _router == address(0) || _usdc == address(0)) {
            revert KipuBank_InvalidAddress(address(0));
        }

        balanceUSDC = 0;
        depositsCount = 0;
        withdrawalsCount = 0;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, _admin);

        i_router = IUniswapV2Router02(_router);
        i_uniswapFactory = IUniswapV2Factory(_factory);

        i_usdcToken = _usdc;
        i_bankCap = _amountBankCap;
        i_maxTransaction = _maxTransaction;
    }

    /*/////////////////////
        Receive & Fallback
    /////////////////////*/

    receive() external payable {
        depositETH();
    }

    fallback() external payable {
        depositETH();
    }

    /*/////////////////////
        Deposit Functions
    /////////////////////*/

    /**
     * @notice Deposita ETH y lo convierte automaticamente a USDC
     * @dev Usa Uniswap V2 para el swap con protección de slippage del 2%
     * Sigue el patrón CEI (Checks-Effects-Interactions)
     */
    function depositETH() public payable nonReentrant validateDeposit(msg.value, i_router.WETH()) {
        address[] memory path = new address[](2);
        path[0] = i_router.WETH();
        path[1] = i_usdcToken;

        uint256 estimatedUSDC = _estimateUSDCamount(msg.value, path[0]);
        uint256 minUSDC = (estimatedUSDC * SLIPPAGE_TOLERANCE) / SLIPPAGE_DENOMINATOR;

        uint256[] memory amounts = i_router.swapExactETHForTokens{value: msg.value}(
            minUSDC, path, address(this), block.timestamp + SWAP_DEADLINE
        );

        uint256 usdcReceived = amounts[1];

        //Verifica BankCap Post Swap
        if (balanceUSDC + usdcReceived > i_bankCap) {revert KipuBank_DepositAmountExceeded(balanceUSDC, i_bankCap);}

        s_userBalances[msg.sender] += usdcReceived;
        balanceUSDC += usdcReceived;
        depositsCount++;

        emit KipuBank_SwapExecuted(msg.sender, path[0], path[1], msg.value, usdcReceived);
        emit KipuBank_DepositSuccessful(msg.sender, usdcReceived);
    }

    /**
     * @notice Deposita cualquier token ERC20 y lo convierte a USDC
     * @param _amountIn Cantidad del token a depositar
     * @param _tokenIn Dirección del token a depositar
     * @dev Si el token es USDC, se deposita directamente. Si es otro token, se hace swap.
     */
    function depositERC20(uint256 _amountIn, address _tokenIn)external nonReentrant validateDeposit(_amountIn, _tokenIn){
        uint256 usdcReceived;

        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        if (_tokenIn == i_usdcToken) {
            // Caso 1: Depósito directo de USDC
            usdcReceived = _amountIn;
        } else {
            // Caso 2: Swap Token -> USDC
            usdcReceived = _swapTokenToUSDC(_tokenIn, _amountIn);

            emit KipuBank_SwapExecuted(msg.sender, _tokenIn, i_usdcToken, _amountIn, usdcReceived);
        }

        //Verifica BankCap PostSwap
        if (balanceUSDC + usdcReceived > i_bankCap) {revert KipuBank_DepositAmountExceeded(balanceUSDC, i_bankCap);}

        s_userBalances[msg.sender] += usdcReceived;
        balanceUSDC += usdcReceived;
        depositsCount++;

        emit KipuBank_DepositSuccessful(msg.sender, usdcReceived);
    }

    /*/////////////////////
        Withdraw Functions
    /////////////////////*/

    /**
     * @notice Retira en USDC
     * @param _amountUSDC Cantidad de USDC a retirar
     */
    function withdraw(uint256 _amountUSDC) external nonReentrant validateWithdrawal(_amountUSDC){
        s_userBalances[msg.sender] -= _amountUSDC;
        balanceUSDC -= _amountUSDC;

        IERC20(i_usdcToken).safeTransfer(msg.sender, _amountUSDC);

        withdrawalsCount++;
        emit KipuBank_WithdrawSuccessful(msg.sender, _amountUSDC);
    }

    /*/////////////////////
        Admin Functions
    /////////////////////*/

    /**
     * @notice Agrega un nuevo administrador
     * @param _newAdmin Dirección del nuevo administrador
     */
    function addAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert KipuBank_InvalidAddress(_newAdmin);
        _grantRole(ADMIN_ROLE, _newAdmin);
        emit KipuBank_AdminAdded(_newAdmin);
    }

    /*/////////////////////
        Internal Functions
    /////////////////////*/

    /**
     * @notice Valida que se pueda depositar el token.
     * @param _amount Cantidad que se quiere depositar.
     * @param _token Token que se quiere depositar.
     */
    function _validateDeposit(uint256 _amount, address _token) internal view {
        if (_amount == 0) revert KipuBank_InvalidAmount(_amount);

        uint256 estimatedUSDC = _estimateUSDCamount(_amount, _token);
        if (estimatedUSDC > i_maxTransaction) {
            revert KipuBank_TransactionAmountExceeded(_amount, i_maxTransaction);
        }

        if (balanceUSDC + estimatedUSDC > i_bankCap) {
            revert KipuBank_DepositAmountExceeded(balanceUSDC, i_bankCap);
        }
    }

    /**
     * @notice Valida que se pueda retirar ese monto de USDC.
     * @param _amountUSDC Cantidad de USDC que se quiere retirar.
     */
    function _validateWithdrawal(uint256 _amountUSDC) internal view {
        uint256 userBalance = s_userBalances[msg.sender];
        if (_amountUSDC > userBalance) {revert KipuBank_InsufficientBalance(_amountUSDC, userBalance);}
        if (_amountUSDC > i_maxTransaction) {revert KipuBank_TransactionAmountExceeded(_amountUSDC, i_maxTransaction);}
        if (_amountUSDC == 0) revert KipuBank_InvalidAmount(_amountUSDC);
    }

    /**
     *  @notice Estima la cantidad de USDC a ser recibida.
     *  @param _amountIn Cantidad del token a convertir.
     *  @param _tokenIn Direccion del token a transmitir.
     */
    function _estimateUSDCamount(uint256 _amountIn, address _tokenIn) internal view returns (uint256 estimatedUSDC) {
        if (_tokenIn == i_usdcToken) {return _amountIn;}

        address[] memory path;

        if(_hasPairWithUSDC(_tokenIn)){
            path = new address[](2);
            path[0] = _tokenIn;
            path[1] = i_usdcToken;
        }else{
            path = new address[](3);
            path[0] = _tokenIn;
            path[1] = i_router.WETH();
            path[2] = i_usdcToken;
        }

        uint256[] memory amountsOut = i_router.getAmountsOut(_amountIn, path);
        return amountsOut[path.length - 1];
    }

    /**
     * @notice Swap interno de cualquier token a USDC
     * @param _tokenIn Token de entrada
     * @param _amountIn Cantidad a intercambiar
     * @return usdcOut Cantidad de USDC recibida
     */
    function _swapTokenToUSDC(address _tokenIn, uint256 _amountIn) internal returns (uint256 usdcOut) {
        SafeERC20.forceApprove(IERC20(_tokenIn), address(i_router), _amountIn);

        address[] memory path;

        if(_hasPairWithUSDC(_tokenIn)){
            path = new address[](2);
            path[0] = _tokenIn;
            path[1] = i_usdcToken;
        }else{
            path = new address[](3);
            path[0] = _tokenIn;
            path[1] = i_router.WETH();
            path[2] = i_usdcToken;
        }

        uint256[] memory amountsOut = i_router.getAmountsOut(_amountIn, path);
        uint256 expectedUSDC = amountsOut[path.length-1];
        uint256 minUSDC = (expectedUSDC * SLIPPAGE_TOLERANCE) / SLIPPAGE_DENOMINATOR;

        uint256[] memory amounts =
            i_router.swapExactTokensForTokens(_amountIn, minUSDC, path, address(this), block.timestamp + SWAP_DEADLINE);

        usdcOut = amounts[path.length-1];
    }

    function _hasPairWithUSDC(address token) internal view returns (bool) {
        address pair = i_uniswapFactory.getPair(token, address(IERC20(i_usdcToken)));
        return pair != address(0);
    }

    /*/////////////////////
        View Functions
    /////////////////////*/

    /**
     * @notice Consulta el balance en USDC de un usuario
     * @return balance Balance del usuario en USDC
     */
    function consultarSaldoUSDC() external view returns (uint256 balance) {
        balance = s_userBalances[msg.sender];
    }
}
