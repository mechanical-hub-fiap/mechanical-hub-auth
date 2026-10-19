import { describe, expect, it } from 'vitest';
import { authorizeAccess, extractBearerToken } from '../../src/core/usecases/authorize-access.js';
import type { AccessTokenClaims } from '../../src/core/ports/token-service.js';
import { FakeTokenService, silentLogger } from '../support/fakes.js';

function claims(role: AccessTokenClaims['role']): AccessTokenClaims {
  return {
    userId: '11111111-1111-4111-8111-111111111111',
    name: 'Maria Silva',
    documentNumber: '52998224725',
    role,
  };
}

function depsWithValidToken(role: AccessTokenClaims['role']) {
  return {
    tokens: new FakeTokenService({ valid: true, claims: claims(role) }),
    logger: silentLogger(),
  };
}

describe('authorizeAccess — rotas publicas', () => {
  it.each([
    ['/auth/login', 'POST'],
    ['/mechanical-hub/service-orders/OS-1', 'GET'],
    ['/mechanical-hub/service-orders/OS-1/approve', 'POST'],
    ['/webhooks/payment', 'POST'],
  ])('%s %s libera sem token', async (path, method) => {
    const outcome = await authorizeAccess(
      { authorizationHeader: null, path, method },
      { tokens: new FakeTokenService(), logger: silentLogger() },
    );

    expect(outcome.effect).toBe('ALLOW_ANONYMOUS');
  });
});

describe('authorizeAccess — token ausente ou malformado', () => {
  it('nega com 401 quando nao ha cabecalho', async () => {
    const outcome = await authorizeAccess(
      { authorizationHeader: null, path: '/orders', method: 'GET' },
      { tokens: new FakeTokenService(), logger: silentLogger() },
    );

    expect(outcome).toMatchObject({ effect: 'DENY', status: 401, reason: 'MISSING_TOKEN' });
  });

  it('nega com 401 quando o cabecalho nao usa Bearer', async () => {
    const outcome = await authorizeAccess(
      { authorizationHeader: 'Basic abc', path: '/orders', method: 'GET' },
      { tokens: new FakeTokenService(), logger: silentLogger() },
    );

    expect(outcome).toMatchObject({ effect: 'DENY', status: 401, reason: 'MALFORMED_HEADER' });
  });
});

describe('authorizeAccess — token invalido', () => {
  it('nega com 401 quando o token expirou', async () => {
    const outcome = await authorizeAccess(
      { authorizationHeader: 'Bearer abc', path: '/orders', method: 'GET' },
      { tokens: new FakeTokenService({ valid: false, reason: 'EXPIRED' }), logger: silentLogger() },
    );

    expect(outcome).toMatchObject({ effect: 'DENY', status: 401, reason: 'EXPIRED_TOKEN' });
  });

  it('nega com 401 quando a assinatura nao confere', async () => {
    const outcome = await authorizeAccess(
      { authorizationHeader: 'Bearer abc', path: '/orders', method: 'GET' },
      {
        tokens: new FakeTokenService({ valid: false, reason: 'INVALID_SIGNATURE' }),
        logger: silentLogger(),
      },
    );

    expect(outcome).toMatchObject({ effect: 'DENY', status: 401, reason: 'INVALID_TOKEN' });
  });
});

// Rota protegida x perfil, uma linha por rota da secao 2 da spec.
describe('authorizeAccess — rota x perfil', () => {
  it.each([
    // rota, metodo, administrador, mecanico
    ['/orders', 'POST', true, true],
    ['/orders', 'GET', true, true],
    ['/orders/1', 'GET', true, true],
    ['/orders/1/repairs', 'PATCH', true, true],
    ['/orders/1/status', 'PATCH', true, true],
    ['/orders/status', 'POST', true, true],
    ['/services', 'GET', true, true],
    ['/stock', 'GET', true, false],
    ['/stock/entry', 'POST', true, false],
    ['/stock/1/movements', 'GET', true, false],
    ['/transaction/1', 'GET', true, false],
  ] as const)('%s %s', async (path, method, adminAllowed, mechanicAllowed) => {
    const asAdmin = await authorizeAccess(
      { authorizationHeader: 'Bearer abc', path, method },
      depsWithValidToken('ADMINISTRATOR'),
    );
    const asMechanic = await authorizeAccess(
      { authorizationHeader: 'Bearer abc', path, method },
      depsWithValidToken('MECHANICAL'),
    );

    const denied = { effect: 'DENY', status: 403, reason: 'INSUFFICIENT_ROLE' };
    expect(asAdmin).toMatchObject(adminAllowed ? { effect: 'ALLOW' } : denied);
    expect(asMechanic).toMatchObject(mechanicAllowed ? { effect: 'ALLOW' } : denied);
  });
});

describe('authorizeAccess — rota desconhecida', () => {
  it.each(['/rota-nova', '/customers/1', '/service-orders', '/actuator/health'])(
    '%s e negada mesmo com token valido de administrador',
    async (path) => {
      const outcome = await authorizeAccess(
        { authorizationHeader: 'Bearer abc', path, method: 'GET' },
        depsWithValidToken('ADMINISTRATOR'),
      );

      expect(outcome).toMatchObject({ effect: 'DENY', status: 403, reason: 'UNKNOWN_ROUTE' });
    },
  );
});

describe('extractBearerToken', () => {
  it.each([
    ['Bearer abc', 'abc'],
    ['bearer abc', 'abc'],
    ['  Bearer   abc  ', 'abc'],
  ])('extrai o token de %s', (header, expected) => {
    expect(extractBearerToken(header)).toBe(expected);
  });

  it.each([null, undefined, '', 'Bearer', 'Bearer   ', 'Basic abc'])(
    'retorna null para %s',
    (header) => {
      expect(extractBearerToken(header as string | null | undefined)).toBeNull();
    },
  );
});
