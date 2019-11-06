pragma solidity ^0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/EtherTokenConstant.sol";
import "@aragon/os/contracts/common/SafeERC20.sol";
import "@aragon/os/contracts/lib/token/ERC20.sol";
import "@aragon/apps-token-manager/contracts/TokenManager.sol";
import "./lib/UintArrayLib.sol";
import "./lib/AddressArrayLib.sol";

/**
* The expected use of this app requires the FINALISE_TOKEN_REQUEST_ROLE permission be given exclusively to a forwarder.
* A user can then request tokens by calling createTokenRequest() to deposit funds and then calling finaliseTokenRequest()
* which will be called via the forwarder if forwarding is successful, minting the user tokens.
*/
contract TokenRequest is AragonApp {

    using SafeERC20 for ERC20;
    using UintArrayLib for uint256[];
    using AddressArrayLib for address[];

    bytes32 constant public SET_TOKEN_MANAGER_ROLE = keccak256("SET_TOKEN_MANAGER_ROLE");
    bytes32 constant public SET_VAULT_ROLE = keccak256("SET_VAULT_ROLE");
    bytes32 constant public FINALISE_TOKEN_REQUEST_ROLE = keccak256("FINALISE_TOKEN_REQUEST_ROLE");
    bytes32 constant public MODIFY_TOKENS_ROLE = keccak256("MODIFY_TOKENS_ROLE");

    string private constant ERROR_TOO_MANY_ACCEPTED_TOKENS = "TOKEN_REQUEST_TOO_MANY_ACCEPTED_TOKENS";
    string private constant ERROR_TOKEN_ALREADY_ACCEPTED = "TOKEN_REQUEST_TOKEN_ALREADY_ACCEPTED";
    string private constant ERROR_TOKEN_NOT_ACCEPTED = "TOKEN_REQUEST_TOKEN_NOT_ACCEPTED";
    string private constant ERROR_ADDRESS_NOT_CONTRACT = "TOKEN_REQUEST_ADDRESS_NOT_CONTRACT";
    string private constant ERROR_TOKEN_REQUEST_NOT_OWNER = "TOKEN_REQUEST_NOT_OWNER";
    string private constant ERROR_TOKEN_REQUEST_NOT_PENDING = "TOKEN_REQUEST_NOT_PENDING";
    string private constant ERROR_ETH_VALUE_MISMATCH = "TOKEN_REQUEST_ETH_VALUE_MISMATCH";
    string private constant ERROR_ETH_TRANSFER_FAILED = "TOKEN_REQUEST_ETH_TRANSFER_FAILED";
    string private constant ERROR_TOKEN_TRANSFER_REVERTED = "TOKEN_REQUEST_TOKEN_TRANSFER_REVERTED";
    string private constant ERROR_NO_REQUEST = "TOKEN_REQUEST_NO_REQUEST";

    uint256 public constant MAX_ACCEPTED_DEPOSIT_TOKENS = 100;

    enum TokenRequestStatus { Pending, Refunded, Finalised }

    struct TokenRequest {
        address requesterAddress;
        address depositToken;
        uint256 depositAmount;
        uint256 requestAmount;
        TokenRequestStatus status;
    }

    TokenManager public tokenManager;
    address public vault;

    address[] public acceptedDepositTokens;

    uint256 public nextTokenRequestId;
    mapping(uint256 => TokenRequest) public tokenRequests; // ID => TokenRequest

    event SetTokenManager(address tokenManager);
    event SetVault(address vault);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event TokenRequestCreated(uint256 requestId, address requesterAddress, address depositToken, uint256 depositAmount, uint256 requestAmount, string reference);
    event TokenRequestRefunded(uint256 requestId, address refundToAddress, address refundToken, uint256 refundAmount);
    event TokenRequestFinalised(uint256 requestId, address requester, address depositToken, uint256 depositAmount, uint256 requestAmount);

    modifier TokenRequestExists(uint256 _tokenRequestId) {
        require(_tokenRequestId < nextTokenRequestId, ERROR_NO_REQUEST);
        _;
    }

    function initialize(address _tokenManager, address _vault, address[] _acceptedDepositTokens) external onlyInit {
        require(isContract(_tokenManager), ERROR_ADDRESS_NOT_CONTRACT);
        require(isContract(_vault), ERROR_ADDRESS_NOT_CONTRACT);
        require(_acceptedDepositTokens.length <= MAX_ACCEPTED_DEPOSIT_TOKENS, ERROR_TOO_MANY_ACCEPTED_TOKENS);

        for (uint256 i = 0; i < _acceptedDepositTokens.length; i++) {
            address acceptedDepositToken = _acceptedDepositTokens[i];
            if (acceptedDepositToken != ETH) {
                require(isContract(acceptedDepositToken), ERROR_ADDRESS_NOT_CONTRACT);
            }
        }

        tokenManager = TokenManager(_tokenManager);
        vault = _vault;
        acceptedDepositTokens = _acceptedDepositTokens;

        initialized();
    }

    /**
    * @notice Set the Token Manager to `_tokenManager`.
    * @param _tokenManager The new token manager address
    */
    function setTokenManager(address _tokenManager) external auth(SET_TOKEN_MANAGER_ROLE) {
        require(isContract(_tokenManager), ERROR_ADDRESS_NOT_CONTRACT);

        tokenManager = TokenManager(_tokenManager);
        emit SetTokenManager(_tokenManager);
    }

    /**
    * @notice Set the Vault to `_vault`.
    * @param _vault The new vault address
    */
    function setVault(address _vault) external auth(SET_VAULT_ROLE) {
        require(isContract(_vault), ERROR_ADDRESS_NOT_CONTRACT);

        vault = _vault;
        emit SetVault(_vault);
    }

    /**
    * @notice Add `_token.symbol(): string` to the accepted deposit token request tokens
    * @param _token token address
    */
    function addToken(address _token) external auth(MODIFY_TOKENS_ROLE) {
        require(!acceptedDepositTokens.contains(_token), ERROR_TOKEN_ALREADY_ACCEPTED);
        require(acceptedDepositTokens.length < MAX_ACCEPTED_DEPOSIT_TOKENS, ERROR_TOO_MANY_ACCEPTED_TOKENS);

        if (_token != ETH) {
            require(isContract(_token), ERROR_ADDRESS_NOT_CONTRACT);
        }

        acceptedDepositTokens.push(_token);

        emit TokenAdded(_token);
    }

    /**
    * @notice Remove `_token.symbol(): string` from the accepted deposit token request tokens
    * @param _token token address
    */
    function removeToken(address _token) external auth(MODIFY_TOKENS_ROLE) {
        require(acceptedDepositTokens.deleteItem(_token), ERROR_TOKEN_NOT_ACCEPTED);

        emit TokenRemoved(_token);
    }

    /**
    * @notice Create a token request depositing `@tokenAmount(_depositToken, _depositAmount, true, 18)` in exchange for `@tokenAmount(self.getToken(): address, _requestAmount, true, 18)`
    * @param _depositToken Address of the token being deposited
    * @param _depositAmount Amount of the token being deposited
    * @param _requestAmount Amount of the token being requested
    * @param _reference String detailing request reason
    */
    function createTokenRequest(address _depositToken, uint256 _depositAmount, uint256 _requestAmount, string _reference)
    external
    payable
    returns (uint256)
    {
        require(acceptedDepositTokens.contains(_depositToken), ERROR_TOKEN_NOT_ACCEPTED);

        if (_depositToken == ETH) {
            require(msg.value == _depositAmount, ERROR_ETH_VALUE_MISMATCH);
        } else {
            require(ERC20(_depositToken).safeTransferFrom(msg.sender, address(this), _depositAmount), ERROR_TOKEN_TRANSFER_REVERTED);
        }

        uint256 tokenRequestId = nextTokenRequestId;
        nextTokenRequestId++;

        tokenRequests[tokenRequestId] = TokenRequest(msg.sender, _depositToken, _depositAmount, _requestAmount, TokenRequestStatus.Pending);

        emit TokenRequestCreated(tokenRequestId, msg.sender, _depositToken, _depositAmount, _requestAmount, _reference);

        return tokenRequestId;
    }

    /**
    * @notice Refund the deposit for token request with id `_tokenRequestId` to the creators account.
    * @param _tokenRequestId ID of the Token Request
    */
    function refundTokenRequest(uint256 _tokenRequestId) external nonReentrant TokenRequestExists(_tokenRequestId) {
        TokenRequest storage tokenRequestCopy = tokenRequests[_tokenRequestId];
        require(tokenRequestCopy.requesterAddress == msg.sender, ERROR_TOKEN_REQUEST_NOT_OWNER);
        require(tokenRequestCopy.status == TokenRequestStatus.Pending, ERROR_TOKEN_REQUEST_NOT_PENDING);

        tokenRequestCopy.status = TokenRequestStatus.Refunded;

        address refundToAddress = tokenRequestCopy.requesterAddress;
        address refundToken = tokenRequestCopy.depositToken;
        uint256 refundAmount = tokenRequestCopy.depositAmount;

        if (refundAmount > 0) {
            if (refundToken == ETH) {
                (bool success, ) = refundToAddress.call.value(refundAmount)();
                require(success, ERROR_ETH_TRANSFER_FAILED);
            } else {
                require(ERC20(refundToken).safeTransfer(refundToAddress, refundAmount), ERROR_TOKEN_TRANSFER_REVERTED);
            }
        }

        emit TokenRequestRefunded(_tokenRequestId, refundToAddress, refundToken, refundAmount);
    }

    /**
    * @notice Finalise the token request with id `_tokenRequestId`, minting the requester funds and moving payment
              to the vault.
    * @dev This function's FINALISE_TOKEN_REQUEST_ROLE permission is typically given exclusively to a forwarder.
    *      This function requires the MINT_ROLE permission on the TokenManager specified.
    * @param _tokenRequestId ID of the Token Request
    */
    function finaliseTokenRequest(uint256 _tokenRequestId) external nonReentrant auth(FINALISE_TOKEN_REQUEST_ROLE) TokenRequestExists(_tokenRequestId){
        TokenRequest storage tokenRequestCopy = tokenRequests[_tokenRequestId];
        require(tokenRequestCopy.status == TokenRequestStatus.Pending, ERROR_TOKEN_REQUEST_NOT_PENDING);

        tokenRequestCopy.status = TokenRequestStatus.Finalised;

        address requesterAddress = tokenRequestCopy.requesterAddress;
        address depositToken = tokenRequestCopy.depositToken;
        uint256 depositAmount = tokenRequestCopy.depositAmount;
        uint256 requestAmount = tokenRequestCopy.requestAmount;

        if (depositAmount > 0) {
            if (depositToken == ETH) {
                (bool success, ) = vault.call.value(depositAmount)();
                require(success, ERROR_ETH_TRANSFER_FAILED);
            } else {
                require(ERC20(depositToken).safeTransfer(vault, depositAmount), ERROR_TOKEN_TRANSFER_REVERTED);
            }
        }

        tokenManager.mint(requesterAddress, requestAmount);

        emit TokenRequestFinalised(_tokenRequestId, requesterAddress, depositToken, depositAmount, requestAmount);
    }

    function getAcceptedDepositTokens() public view returns (address[]) {
        return acceptedDepositTokens;
    }

    function getTokenRequest(uint256 _tokenRequestId) public view
    returns (
        address requesterAddress,
        address depositToken,
        uint256 depositAmount,
        uint256 requestAmount
    )
    {
        TokenRequest storage tokenRequest = tokenRequests[_tokenRequestId];

        requesterAddress = tokenRequest.requesterAddress;
        depositToken = tokenRequest.depositToken;
        depositAmount = tokenRequest.depositAmount;
        requestAmount = tokenRequest.requestAmount;
    }

    /**
    * @dev Convenience function for getting the token request token in a radspec string
    */
    function getToken() public returns (address) {
        return tokenManager.token();
    }

}
